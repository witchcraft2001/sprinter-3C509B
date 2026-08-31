.PHONY: all build test-host test-exe-stress package image clean

all: build

build:
	tools/build.sh

test-host:
	tools/test-host.sh

test-exe-stress: build
	node tools/test-exe-stress.js

package:
	tools/package.sh

image:
	tools/image.sh

clean:
	rm -rf build
	rm -f distr/sprinter-3c509b.zip distr/sprinter-3c509b.img
