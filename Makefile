.PHONY: all build test-host package image clean

all: build

build:
	tools/build.sh

test-host:
	tools/test-host.sh

package:
	tools/package.sh

image:
	tools/image.sh

clean:
	rm -rf build
	rm -f distr/sprinter-3c509b.zip distr/sprinter-3c509b.img
