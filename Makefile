.PHONY: all sync build clean

all: sync build

sync:
	./scripts/sync-openwrt.sh

build:
	./scripts/build-openwrt.sh

clean:
	rm -rf workdir/openwrt artifacts
