SPACE := $(subst ,, )
HEADERS_DESTDIR_ESCAPED=$(subst $(SPACE),\ ,${HEADERS_DESTDIR})

all: ${HEADERS_DESTDIR_ESCAPED}/mpv/*.h

MPV_HEADERS_REPOSITORY?=Yuch3nE/mpv
MPV_HEADERS_VERSION?=v0.41.0.patch-gpu-next
MPV_HEADERS_SHA256SUM?=
MPV_HEADERS_URL?=https://github.com/${MPV_HEADERS_REPOSITORY}/archive/refs/tags/${MPV_HEADERS_VERSION}.tar.gz

TAR=tar
TAR_WILDCARDS_FLAG := $(shell ${TAR} --version 2>&1 | grep -q 'GNU' && echo "--wildcards" || echo "")

.cache/headers/mpv-${MPV_HEADERS_VERSION}.tar.gz:
	mkdir -p .cache/headers
	rm -f .cache/headers/*.tmp .cache/headers/*.tar.gz
	curl -L "${MPV_HEADERS_URL}" -o .cache/headers/mpv.tar.gz.tmp
	if [ -n "${MPV_HEADERS_SHA256SUM}" ]; then \
		printf '%s  %s\n' '${MPV_HEADERS_SHA256SUM}' '.cache/headers/mpv.tar.gz.tmp' | shasum -a 256 -c -; \
	else \
		echo 'Skipping SHA256 verification because MPV_HEADERS_SHA256SUM is empty.'; \
	fi
	mv .cache/headers/mpv.tar.gz.tmp .cache/headers/mpv-${MPV_HEADERS_VERSION}.tar.gz
	touch .cache/headers/mpv-${MPV_HEADERS_VERSION}.tar.gz

.cache/headers/mpv.tar.gz: .cache/headers/mpv-${MPV_HEADERS_VERSION}.tar.gz
	rm -f .cache/headers/mpv.tar.gz
	ln -s mpv-${MPV_HEADERS_VERSION}.tar.gz .cache/headers/mpv.tar.gz

${HEADERS_DESTDIR_ESCAPED}/mpv/*.h: .cache/headers/mpv.tar.gz
	mkdir -p ${HEADERS_DESTDIR_ESCAPED}/mpv
	${TAR} ${TAR_WILDCARDS_FLAG} -xvf .cache/headers/mpv.tar.gz --strip-components 2 -C ${HEADERS_DESTDIR_ESCAPED}/mpv/ 'mpv-*/libmpv/*.h'
	perl -0pi -e 's/(\n[[:space:]]*} mpv_render_param_type;)/\n    MPV_RENDER_PARAM_BACKEND = 21,\1/ if !/MPV_RENDER_PARAM_BACKEND/' ${HEADERS_DESTDIR_ESCAPED}/mpv/render.h
	touch ${HEADERS_DESTDIR_ESCAPED}/mpv/*.h
