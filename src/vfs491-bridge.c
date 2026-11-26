#define _GNU_SOURCE

#include "vfs491-protocol.h"

#include <endian.h>
#include <errno.h>
#include <dirent.h>
#include <fcntl.h>
#include <poll.h>
#include <limits.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/prctl.h>
#include <time.h>
#include <unistd.h>

#define HELPER_TIMEOUT_MS 105000
#define LOG_CAPTURE_MAX 65536u
#define META_SIZE 12u
#define READY_SIZE 8u
#define READY_STATUS UINT64_C(0xAAAAAAAAAAAAAAAA)

struct helper_input {
    int32_t ready_fd;
    int32_t metadata_fd;
    int32_t image_fd;
} __attribute__((packed));

struct helper_metadata {
    int32_t image_len;
    int32_t width;
    int32_t height;
} __attribute__((packed));

static volatile sig_atomic_t stop_requested = 0;

static void on_stop_signal(int signo)
{
    (void)signo;
    stop_requested = 1;
}

static void write_stderr_best_effort(const void *buffer, size_t length)
{
    const unsigned char *p = buffer;

    while (length > 0) {
        ssize_t written = write(STDERR_FILENO, p, length);
        if (written > 0) {
            p += (size_t)written;
            length -= (size_t)written;
            continue;
        }
        if (written < 0 && errno == EINTR)
            continue;
        break;
    }
}

static void log_message(const char *message)
{
    write_stderr_best_effort(message, strlen(message));
}

static int set_nonblock(int fd)
{
    int flags = fcntl(fd, F_GETFL);
    if (flags < 0)
        return -1;
    return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static int64_t monotonic_ms(void);

/* The vendor daemon leaves /tmp/vcsSemKey_ServiceReady behind when it exits.
 * Never trust that marker on its own: require a live process with the expected
 * comm name as well.  This prevents stale-marker false positives. */
static bool hp_service_process_present(void)
{
    DIR *proc = opendir("/proc");
    if (!proc)
        return false;

    bool found = false;
    struct dirent *entry;
    while ((entry = readdir(proc)) != NULL) {
        if (!entry->d_name[0])
            continue;
        bool numeric = true;
        for (const char *p = entry->d_name; *p; ++p) {
            if (*p < '0' || *p > '9') {
                numeric = false;
                break;
            }
        }
        if (!numeric)
            continue;

        char path[128];
        int n = snprintf(path, sizeof(path), "/proc/%s/comm", entry->d_name);
        if (n <= 0 || (size_t)n >= sizeof(path))
            continue;
        FILE *comm = fopen(path, "re");
        if (!comm)
            continue;
        char name[128] = {0};
        bool ok = fgets(name, sizeof(name), comm) != NULL;
        fclose(comm);
        if (!ok)
            continue;
        name[strcspn(name, "\r\n")] = '\0';
        if (strcmp(name, "vcsFPService") == 0) {
            found = true;
            break;
        }

        /* comm can be shortened/overridden.  Verify the executable basename
         * as a fallback, rather than matching any process containing the text. */
        n = snprintf(path, sizeof(path), "/proc/%s/exe", entry->d_name);
        if (n > 0 && (size_t)n < sizeof(path)) {
            char executable[512] = {0};
            ssize_t exe_len = readlink(path, executable, sizeof(executable) - 1);
            if (exe_len > 0) {
                executable[exe_len] = '\0';
                const char *base = strrchr(executable, '/');
                base = base ? base + 1 : executable;
                if (strcmp(base, "vcsFPService") == 0) {
                    found = true;
                    break;
                }
            }
        }
    }

    closedir(proc);
    return found;
}

static const char *ready_marker_path(void)
{
    const char *override = getenv("VFS491_READY_MARKER");
    return (override && *override) ? override : "/tmp/vcsSemKey_ServiceReady";
}

static bool hp_service_ready(void)
{
    struct stat marker;
    return stat(ready_marker_path(), &marker) == 0 &&
           hp_service_process_present();
}

static bool wait_for_hp_service_ready(void)
{
    const char *value = getenv("VFS491_SERVICE_START_WAIT_MS");
    unsigned long wait_ms = 15000;
    if (value && *value) {
        char *end = NULL;
        errno = 0;
        unsigned long parsed = strtoul(value, &end, 10);
        if (!errno && end != value && !*end && parsed <= 60000)
            wait_ms = parsed;
    }

    const int64_t deadline = monotonic_ms() + (int64_t)wait_ms;
    do {
        if (hp_service_ready())
            return true;
        usleep(200000);
    } while (monotonic_ms() < deadline);
    return hp_service_ready();
}

static int clear_cloexec(int fd)
{
    int flags = fcntl(fd, F_GETFD);
    if (flags < 0)
        return -1;
    return fcntl(fd, F_SETFD, flags & ~FD_CLOEXEC);
}

static int make_pipe(int fds[2])
{
#ifdef __linux__
    return pipe2(fds, O_CLOEXEC);
#else
    if (pipe(fds) < 0)
        return -1;
    (void)fcntl(fds[0], F_SETFD, FD_CLOEXEC);
    (void)fcntl(fds[1], F_SETFD, FD_CLOEXEC);
    return 0;
#endif
}

static int write_all(int fd, const void *buffer, size_t length)
{
    const unsigned char *p = buffer;
    size_t done = 0;
    while (done < length) {
        ssize_t n = write(fd, p + done, length - done);
        if (n > 0) {
            done += (size_t)n;
            continue;
        }
        if (n < 0 && errno == EINTR)
            continue;
        return -1;
    }
    return 0;
}

static int64_t monotonic_ms(void)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) < 0)
        return 0;
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static unsigned int bridge_timeout_ms(void)
{
    const char *value = getenv("VFS491_BRIDGE_TIMEOUT_MS");
    char *end = NULL;
    unsigned long parsed;
    if (!value || !*value)
        return HELPER_TIMEOUT_MS;
    errno = 0;
    parsed = strtoul(value, &end, 10);
    if (errno || end == value || *end || parsed < 1000 || parsed > 600000)
        return HELPER_TIMEOUT_MS;
    return (unsigned int)parsed;
}

/* Do not restart vcsFPService from this bridge. The bridge runs inside an
 * active libfprint capture session. Restarting the proprietary daemon can
 * reset/re-enumerate USB 138a:003d while libfprint still owns the old device
 * object, producing DEVICE_REMOVED and stale bus/device numbers. Recovery is
 * deliberately deferred until the caller has closed the device session. */
static void terminate_child(pid_t child, bool already_reaped, int *status)
{
    if (child <= 0 || already_reaped)
        return;

    (void)kill(child, SIGTERM);
    for (unsigned int i = 0; i < 25; ++i) {
        pid_t r = waitpid(child, status, WNOHANG);
        if (r == child || (r < 0 && errno == ECHILD))
            return;
        usleep(20000);
    }

    (void)kill(child, SIGKILL);
    while (waitpid(child, status, 0) < 0 && errno == EINTR)
        ;
}

static void close_fd(int *fd)
{
    if (*fd >= 0) {
        (void)close(*fd);
        *fd = -1;
    }
}

static int drain_fd(int *fd, unsigned char *buffer, size_t capacity,
                    size_t *used, bool *eof)
{
    unsigned char discard[4096];
    for (;;) {
        unsigned char *dst = buffer ? buffer + *used : discard;
        size_t room = buffer ? capacity - *used : sizeof(discard);
        unsigned char extra_byte;
        if (room == 0) {
            ssize_t extra = read(*fd, &extra_byte, 1);
            if (extra == 0) {
                *eof = true;
                close_fd(fd);
                return 0;
            }
            if (extra > 0)
                return -2;
            if (errno == EINTR)
                continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK)
                return 0;
            return -1;
        }
        ssize_t n = read(*fd, dst, room);
        if (n > 0) {
            if (buffer)
                *used += (size_t)n;
            continue;
        }
        if (n == 0) {
            *eof = true;
            close_fd(fd);
            return 0;
        }
        if (errno == EINTR)
            continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK)
            return 0;
        return -1;
    }
}

static int run_capture(const char *helper_path)
{
    int ready[2] = {-1, -1};
    int metadata[2] = {-1, -1};
    int image[2] = {-1, -1};
    int child_in[2] = {-1, -1};
    int child_log[2] = {-1, -1};
    int read_fds[4] = {-1, -1, -1, -1};
    bool eof[4] = {false, false, false, false};
    size_t ready_used = 0, metadata_used = 0, image_used = 0, log_used = 0;
    unsigned char ready_buf[READY_SIZE] = {0};
    bool ready_valid = false;
    unsigned char metadata_buf[META_SIZE] = {0};
    unsigned char *image_buf = NULL;
    char log_buf[LOG_CAPTURE_MAX + 1] = {0};
    struct helper_metadata parsed = {0};
    bool metadata_valid = false;
    pid_t child = -1;
    int child_status = 0;
    bool child_reaped = false;
    int result = 1;
    const int64_t deadline = monotonic_ms() + bridge_timeout_ms();
    image_buf = malloc(VFS491_MAX_IMAGE_BYTES);
    if (!image_buf) {
        perror("vfs491-bridge: allocating image buffer");
        return 1;
    }

    if (!getenv("VFS491_TEST_SKIP_SERVICE_CHECK") && !wait_for_hp_service_ready()) {
        struct stat marker;
        if (stat(ready_marker_path(), &marker) == 0)
            log_message("vfs491-bridge: stale service marker detected; no live vcsFPService process\n");
        else
            log_message("vfs491-bridge: HP service did not become ready before the startup wait expired\n");
        return 3;
    }

    if (make_pipe(ready) < 0 || make_pipe(metadata) < 0 ||
        make_pipe(image) < 0 || make_pipe(child_in) < 0 ||
        make_pipe(child_log) < 0) {
        perror("vfs491-bridge: pipe");
        goto out;
    }

    /* The proprietary helper receives these write descriptors as three ints. */
    const int ready_child_fd = ready[1];
    const int metadata_child_fd = metadata[1];
    const int image_child_fd = image[1];
    if (clear_cloexec(ready_child_fd) < 0 ||
        clear_cloexec(metadata_child_fd) < 0 ||
        clear_cloexec(image_child_fd) < 0) {
        perror("vfs491-bridge: clear close-on-exec");
        goto out;
    }

    const char *libdir = getenv("VFS491_HP_LIBDIR");
    if (libdir && *libdir) {
        char wrapper_path[PATH_MAX];
        int path_len = snprintf(wrapper_path, sizeof(wrapper_path),
                                "%s/libvfsFprintWrapper.so", libdir);
        if (path_len <= 0 || (size_t)path_len >= sizeof(wrapper_path)) {
            log_message("vfs491-bridge: vendor wrapper path is too long\n");
            goto out;
        }
        if (setenv("LD_LIBRARY_PATH", libdir, 1) < 0 ||
            setenv("VFS491_WRAPPER", wrapper_path, 1) < 0) {
            perror("vfs491-bridge: set vendor library environment");
            goto out;
        }
    }

    const pid_t bridge_pid = getpid();
    child = fork();
    if (child < 0) {
        perror("vfs491-bridge: fork");
        goto out;
    }

    if (child == 0) {
        if (prctl(PR_SET_PDEATHSIG, SIGTERM) < 0 || getppid() != bridge_pid)
            _exit(125);

        /* Do not leak the bridge's SIGPIPE policy into the legacy helper. */
        struct sigaction child_pipe;
        memset(&child_pipe, 0, sizeof(child_pipe));
        child_pipe.sa_handler = SIG_DFL;
        sigemptyset(&child_pipe.sa_mask);
        (void)sigaction(SIGPIPE, &child_pipe, NULL);

        if (dup2(child_in[0], STDIN_FILENO) < 0 ||
            dup2(child_log[1], STDOUT_FILENO) < 0 ||
            dup2(child_log[1], STDERR_FILENO) < 0)
            _exit(126);

        close(ready[0]);
        close(metadata[0]);
        close(image[0]);
        close(child_in[0]);
        close(child_in[1]);
        close(child_log[0]);
        close(child_log[1]);

        char *const helper_argv[] = {(char *)helper_path, NULL};
        execv(helper_path, helper_argv);
        const char msg[] = "vfs491-bridge: exec vendor helper failed\n";
        write_stderr_best_effort(msg, sizeof(msg) - 1);
        _exit(127);
    }

    close_fd(&ready[1]);
    close_fd(&metadata[1]);
    close_fd(&image[1]);
    close_fd(&child_in[0]);
    close_fd(&child_log[1]);

    struct helper_input input = {
        .ready_fd = ready_child_fd,
        .metadata_fd = metadata_child_fd,
        .image_fd = image_child_fd,
    };
    if (write_all(child_in[1], &input, sizeof(input)) < 0) {
        perror("vfs491-bridge: passing IPC descriptors");
        goto out;
    }
    close_fd(&child_in[1]);

    read_fds[0] = ready[0]; ready[0] = -1;
    read_fds[1] = metadata[0]; metadata[0] = -1;
    read_fds[2] = image[0]; image[0] = -1;
    read_fds[3] = child_log[0]; child_log[0] = -1;
    for (size_t i = 0; i < 4; ++i) {
        if (set_nonblock(read_fds[i]) < 0) {
            perror("vfs491-bridge: set nonblocking");
            goto out;
        }
    }

    while (true) {
        if (stop_requested) {
            log_message("vfs491-bridge: termination requested\n");
            goto out;
        }
        if (monotonic_ms() >= deadline) {
            log_message("vfs491-bridge: outer capture deadline reached; proprietary session is tainted and must be reset after claim close\n");
            result = VFS491_BROKER_ERR_NO_SWIPE_SESSION_RESET;
            goto out;
        }

        struct pollfd pfds[4];
        for (size_t i = 0; i < 4; ++i) {
            pfds[i].fd = read_fds[i];
            pfds[i].events = (read_fds[i] >= 0) ? (POLLIN | POLLHUP | POLLERR) : 0;
            pfds[i].revents = 0;
        }

        int pr = poll(pfds, 4, 200);
        if (pr < 0) {
            if (errno == EINTR)
                continue;
            perror("vfs491-bridge: poll");
            goto out;
        }

        for (size_t i = 0; i < 4; ++i) {
            if (read_fds[i] < 0 || !(pfds[i].revents & (POLLIN | POLLHUP | POLLERR)))
                continue;

            if (i == 0) {
                int rr = drain_fd(&read_fds[i], ready_buf, sizeof(ready_buf),
                                  &ready_used, &eof[i]);
                if (rr != 0 || ready_used > READY_SIZE) {
                    log_message("vfs491-bridge: invalid ready-pipe data\n");
                    goto out;
                }
                if (ready_used == READY_SIZE && !ready_valid) {
                    uint64_t status_value = 0;
                    memcpy(&status_value, ready_buf, sizeof(status_value));
                    if (status_value != READY_STATUS) {
                        log_message("vfs491-bridge: unrecognized helper-ready status\n");
                        goto out;
                    }
                    ready_valid = true;
                }
            } else if (i == 1) {
                int rr = drain_fd(&read_fds[i], metadata_buf, sizeof(metadata_buf),
                                  &metadata_used, &eof[i]);
                if (rr != 0 || metadata_used > META_SIZE) {
                    log_message("vfs491-bridge: invalid metadata-pipe data\n");
                    goto out;
                }
                if (metadata_used == META_SIZE && !metadata_valid) {
                    memcpy(&parsed, metadata_buf, sizeof(parsed));
                    if (parsed.image_len <= 0 ||
                        parsed.width != (int32_t)VFS491_IMAGE_WIDTH ||
                        parsed.height <= 0 ||
                        parsed.height > (int32_t)VFS491_MAX_IMAGE_HEIGHT ||
                        parsed.image_len != parsed.width * parsed.height ||
                        (uint32_t)parsed.image_len > VFS491_MAX_IMAGE_BYTES) {
                        log_message("vfs491-bridge: rejected impossible image dimensions/length\n");
                        goto out;
                    }
                    if (image_used > (size_t)parsed.image_len) {
                        log_message("vfs491-bridge: image data preceded metadata and exceeded declared length\n");
                        goto out;
                    }
                    metadata_valid = true;
                }
            } else if (i == 2) {
                int rr = drain_fd(&read_fds[i], image_buf, VFS491_MAX_IMAGE_BYTES,
                                  &image_used, &eof[i]);
                if (rr != 0 || (metadata_valid && image_used > (size_t)parsed.image_len)) {
                    log_message("vfs491-bridge: image data exceeded allowed size\n");
                    goto out;
                }
            } else {
                size_t before = log_used;
                int rr = drain_fd(&read_fds[i], (unsigned char *)log_buf, LOG_CAPTURE_MAX,
                                  &log_used, &eof[i]);
                if (rr != 0) {
                    log_message("vfs491-bridge: helper log exceeded limit\n");
                    goto out;
                }
                if (log_used > before) {
                    log_buf[log_used] = '\0';
                    write_stderr_best_effort(log_buf + before, log_used - before);
                }
            }
        }

        if (!child_reaped) {
            pid_t wr = waitpid(child, &child_status, WNOHANG);
            if (wr == child)
                child_reaped = true;
            else if (wr < 0 && errno != EINTR) {
                perror("vfs491-bridge: waitpid");
                goto out;
            }
        }

        bool all_eof = true;
        for (size_t i = 0; i < 4; ++i)
            all_eof = all_eof && (eof[i] || read_fds[i] < 0);
        if (child_reaped && all_eof)
            break;
    }

    if (!child_reaped) {
        while (waitpid(child, &child_status, 0) < 0) {
            if (errno == EINTR)
                continue;
            perror("vfs491-bridge: waitpid final");
            goto out;
        }
        child_reaped = true;
    }

    if (!WIFEXITED(child_status)) {
        if (WIFSIGNALED(child_status)) {
            int sig = WTERMSIG(child_status);
            const char *signal_name = strsignal(sig);
            char message[256];
            snprintf(message, sizeof(message),
                     "vfs491-bridge: helper process terminated by signal %d (%s)%s; broker will reset the vendor service after claim close\n",
                     sig, signal_name ? signal_name : "unknown",
                     WCOREDUMP(child_status) ? " [core dumped]" : "");
            log_message(message);
            log_message("vfs491-bridge: HP service restart deferred until the libfprint device session is closed\n");
            result = VFS491_BROKER_ERR_HELPER_FAILURE;
        } else {
            log_message("vfs491-bridge: worker ended with an unrecognized wait status\n");
        }
        goto out;
    }

    int helper_exit = WEXITSTATUS(child_status);
    /* The preserved reference helper exits with status 1 for
     * VFSW_CAPTURE_ERROR after logging this message and reaching its normal
     * cleanup label. It does not use a dedicated exit status such as 117. */
    if (strstr(log_buf, "Could not capture fingerprint") != NULL) {
        log_message("vfs491-bridge: vendor acquisition returned VFSW_CAPTURE_ERROR after helper cleanup; bounded retry is safe\n");
        result = VFS491_BROKER_ERR_ACQUISITION;
        goto out;
    }
    if (helper_exit == 110 && strstr(log_buf, "Timed out waiting for capture") != NULL) {
        log_message("vfs491-bridge: no swipe before vendor timeout; helper exited without vendor API cleanup, so broker must reset service after claim close\n");
        result = VFS491_BROKER_ERR_NO_SWIPE_SESSION_RESET;
        goto out;
    }
    if (helper_exit == 112 || helper_exit == 113 || helper_exit == 114 || helper_exit == 115) {
        log_message("vfs491-bridge: proprietary helper reported an initialization/IPC failure; broker will reset the service after claim close\n");
    }
    if (helper_exit != 0) {
        char msg[128];
        snprintf(msg, sizeof(msg), "vfs491-bridge: proprietary helper exited %d\n", helper_exit);
        log_message(msg);
        goto out;
    }

    if (!metadata_valid || !ready_valid || image_used != (size_t)parsed.image_len) {
        log_message("vfs491-bridge: helper output was incomplete\n");
        goto out;
    }

    struct vfs491_frame_header header = {
        .magic_le = htole32(VFS491_FRAME_MAGIC),
        .version_le = htole32(VFS491_FRAME_VERSION),
        .width_le = htole32((uint32_t)parsed.width),
        .height_le = htole32((uint32_t)parsed.height),
        .image_len_le = htole32((uint32_t)parsed.image_len),
    };

    if (write_all(STDOUT_FILENO, &header, sizeof(header)) < 0 ||
        write_all(STDOUT_FILENO, image_buf, image_used) < 0) {
        perror("vfs491-bridge: writing image frame");
        goto out;
    }

    result = 0;

out:
    if (child > 0 && !child_reaped) {
        terminate_child(child, false, &child_status);
        if (stop_requested)
            log_message("vfs491-bridge: capture cancelled; HP service left running to preserve USB enumeration\n");
    }
    for (size_t i = 0; i < 4; ++i)
        close_fd(&read_fds[i]);
    for (size_t i = 0; i < 2; ++i) {
        close_fd(&ready[i]);
        close_fd(&metadata[i]);
        close_fd(&image[i]);
        close_fd(&child_in[i]);
        close_fd(&child_log[i]);
    }
    free(image_buf);
    return result;
}

int main(int argc, char **argv)
{
    /* The broker owns this bridge process. If the broker crashes, terminate
     * the isolated helper too; otherwise an orphaned capture could continue
     * using the vendor IPC session after the client has disappeared. */
    pid_t broker_pid = getppid();
    if (prctl(PR_SET_PDEATHSIG, SIGTERM) < 0 || getppid() != broker_pid) {
        perror("vfs491-bridge: establish broker parent-death signal");
        return 125;
    }

    if (argc != 2 || !argv[1] || !*argv[1]) {
        fprintf(stderr, "Usage: %s /path/to/vfs_proprietary-capture-helper\n", argv[0]);
        return 2;
    }

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_stop_signal;
    sigemptyset(&sa.sa_mask);
    (void)sigaction(SIGTERM, &sa, NULL);
    (void)sigaction(SIGINT, &sa, NULL);

    struct sigaction ignore_pipe;
    memset(&ignore_pipe, 0, sizeof(ignore_pipe));
    ignore_pipe.sa_handler = SIG_IGN;
    sigemptyset(&ignore_pipe.sa_mask);
    (void)sigaction(SIGPIPE, &ignore_pipe, NULL);

    return run_capture(argv[1]);
}
