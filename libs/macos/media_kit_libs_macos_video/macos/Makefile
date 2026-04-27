all: Frameworks/*.xcframework Frameworks/.symlinks

MPV_XCFRAMEWORKS_REPOSITORY?=Yuch3nE/mpv-iina-avs
MPV_XCFRAMEWORKS_VERSION?=0.6.7-avs
MPV_XCFRAMEWORKS_RELEASE_TAG?=${MPV_XCFRAMEWORKS_VERSION}
MPV_XCFRAMEWORKS_TARGET_LABEL?=macos-universal
MPV_XCFRAMEWORKS_VARIANT?=video
MPV_XCFRAMEWORKS_FLAVOR?=full
MPV_XCFRAMEWORKS_SHA256SUM?=
MPV_XCFRAMEWORKS_ARCHIVE=libmpv-xcframeworks_${MPV_XCFRAMEWORKS_VERSION}_${MPV_XCFRAMEWORKS_TARGET_LABEL}-${MPV_XCFRAMEWORKS_VARIANT}-${MPV_XCFRAMEWORKS_FLAVOR}.tar.gz
MPV_XCFRAMEWORKS_URL?=https://github.com/${MPV_XCFRAMEWORKS_REPOSITORY}/releases/download/${MPV_XCFRAMEWORKS_RELEASE_TAG}/${MPV_XCFRAMEWORKS_ARCHIVE}

TAR=tar
TAR_WILDCARDS_FLAG := $(shell ${TAR} --version 2>&1 | grep -q 'GNU' && echo "--wildcards" || echo "")

SED=sed
SED_INPLACE_FLAG := $(shell ${SED} --version 2>&1 | grep -q 'GNU' && echo "" || echo "''")

.cache/xcframeworks/libmpv-xcframeworks-${MPV_XCFRAMEWORKS_VERSION}-${MPV_XCFRAMEWORKS_TARGET_LABEL}.tar.gz:
	mkdir -p .cache/xcframeworks
	rm -f .cache/xcframeworks/*.tmp .cache/xcframeworks/*.tar.gz
	curl -L "${MPV_XCFRAMEWORKS_URL}" -o .cache/xcframeworks/libmpv.tar.gz.tmp
	if [ -n "${MPV_XCFRAMEWORKS_SHA256SUM}" ]; then \
		printf '%s  %s\n' '${MPV_XCFRAMEWORKS_SHA256SUM}' '.cache/xcframeworks/libmpv.tar.gz.tmp' | shasum -a 256 -c -; \
	else \
		echo 'Skipping SHA256 verification because MPV_XCFRAMEWORKS_SHA256SUM is empty.'; \
	fi
	mv .cache/xcframeworks/libmpv.tar.gz.tmp .cache/xcframeworks/libmpv-xcframeworks-${MPV_XCFRAMEWORKS_VERSION}-${MPV_XCFRAMEWORKS_TARGET_LABEL}.tar.gz
	touch .cache/xcframeworks/libmpv-xcframeworks-${MPV_XCFRAMEWORKS_VERSION}-${MPV_XCFRAMEWORKS_TARGET_LABEL}.tar.gz

.cache/xcframeworks/libmpv-xcframeworks-macos-universal.tar.gz: .cache/xcframeworks/libmpv-xcframeworks-${MPV_XCFRAMEWORKS_VERSION}-${MPV_XCFRAMEWORKS_TARGET_LABEL}.tar.gz
	rm -f .cache/xcframeworks/libmpv-xcframeworks-macos-universal.tar.gz
	ln -s libmpv-xcframeworks-${MPV_XCFRAMEWORKS_VERSION}-${MPV_XCFRAMEWORKS_TARGET_LABEL}.tar.gz .cache/xcframeworks/libmpv-xcframeworks-macos-universal.tar.gz

Frameworks/*.xcframework: .cache/xcframeworks/libmpv-xcframeworks-macos-universal.tar.gz
	mkdir -p Frameworks
	rm -rf Frameworks/*.xcframework
	${TAR} ${TAR_WILDCARDS_FLAG} -xvf .cache/xcframeworks/libmpv-xcframeworks-macos-universal.tar.gz --strip-components 1 -C Frameworks
	touch Frameworks/*.xcframework

Frameworks/.symlinks: Frameworks/*.xcframework
	rm -rf Frameworks/.symlinks
	mkdir -p Frameworks/.symlinks/mpv
	${SED} -i ${SED_INPLACE_FLAG} 's/\r$$//g' create_framework_symlinks.sh # remove CRLF line terminator added by Flutter packaging (https://github.com/media-kit/media-kit/issues/338)
	sh create_framework_symlinks.sh Frameworks/Mpv.xcframework Frameworks/.symlinks/mpv

.PHONY: clean
clean:
	rm -rf .cache
	rm -f ./Headers/mpv/*.h
	rm -rf ./Frameworks/*.xcframework
