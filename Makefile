.PHONY: preflight bootstrap check build package test isolation-test hardware-test clean

preflight:
	./scripts/preflight.sh

bootstrap:
	./scripts/bootstrap-private-sysroot.sh

check: bootstrap
	./scripts/check-source.sh

build: bootstrap
	./scripts/build.sh

package: preflight build
	./scripts/build-system-deb.sh

test:
	python3 ./tests/test-verify-study.py
	./tests/test-bridge.sh
	python3 ./tests/test-parent-death.py
	./tests/test-transaction-static.sh
	./tests/test-readfull.sh
	python3 ./tests/test-persistent-broker.py
	python3 ./tests/test-broker-recovery.py
	python3 ./tests/test-systemd-readiness.py
	python3 ./tests/test-image-diagnostics.py
	./tests/test-image-metrics.sh
	./tests/test-boot-integration.sh
	./tests/test-pam-config-script.sh
	./tests/test-recovery-script.sh

isolation-test:
	./scripts/check-systemd-isolation.sh

hardware-test:
	sudo systemctl start vfs491d.service
	sudo python3 ./scripts/test-capture-session.py --captures 2 --claims 2

clean:
	rm -rf build/* debs/*
	@touch build/.gitkeep
