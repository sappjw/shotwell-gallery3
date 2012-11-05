PROGRAM := GalleryConnector
ICON := gallery3.png
VERSION := 0.1
VALA_VER := 0.16

S_DIR := /usr/local/src/shotwell-0.13.1/
S_PLUGIN_DIR := $(S_DIR)/plugins/

all: $(PROGRAM).so

clean:
	rm -f $(PROGRAM).c $(PROGRAM).so

install: $(PROGRAM).so
	@ [ `whoami` != "root" ] || ( echo 'Run make install as yourself, not as root.' ; exit 1 )
	mkdir -p ~/.gnome2/shotwell/plugins
	install -m 644 $(PROGRAM).so ~/.gnome2/shotwell/plugins
	install -m 444 $(ICON) ~/.gnome2/shotwell/plugins

uninstall:
	@ [ `whoami` != "root" ] || ( echo 'Run make install as yourself, not as root.' ; exit 1 )
	rm -f ~/.gnome2/shotwell/plugins/$(PROGRAM).so

$(PROGRAM).so: $(PROGRAM).vala Makefile
	valac-$(VALA_VER) --save-temps --main=dummy_main -X -D_VERSION='"$(VERSION)"' \
	  --pkg=shotwell-plugin-dev-1.0 --pkg=libsoup-2.4 --pkg=libxml-2.0 --pkg=json-glib-1.0 \
		-X -I$(S_DIR) \
		-X -DGETTEXT_PACKAGE='"shotwell"' \
		-X --shared -X -fPIC $< $(S_PLUGIN_DIR)/common/RESTSupport.vala $(S_PLUGIN_DIR)/common/Resources.vala $(S_PLUGIN_DIR)/common/ui.vala -o $@
