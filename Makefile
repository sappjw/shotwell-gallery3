PROGRAM := GalleryConnector
ICON := gallery3.png
VERSION := 0.1
VALA_VER := 0.22

S_DIR := /usr/local/src/shotwell-0.15.1
S_PLUGIN_DIR := $(S_DIR)/plugins
DEPS := $(S_PLUGIN_DIR)/common/RESTSupport.vala $(S_PLUGIN_DIR)/common/Resources.vala $(S_DIR)/src/util/ui.vala

# From the Shotwell plugins/Makefile.plugin.mk
PKGS := $(shell sed ':a;N;$$!ba;s/\n/ /g' $(S_PLUGIN_DIR)/shotwell-plugin-dev-1.0.deps) $(PKGS)
# From the Shotwell plugins/shotwell-publishing/Makefile
PLUGIN_PKGS := \
	gtk+-3.0 \
	libsoup-2.4 \
	libxml-2.0 \
	webkitgtk-3.0 \
	gexiv2 \
	rest-0.7 \
	gee-0.8 \
	json-glib-1.0

# automatically include the shotwell-plugin-dev-1.0 package as a local dependency
PKGS := shotwell-plugin-dev-1.0 $(PKGS) $(PLUGIN_PKGS)

all: $(PROGRAM).so

clean:
	rm -f $(PROGRAM).c $(PROGRAM).so Resources.c RESTSupport.c ui.c

install: $(PROGRAM).so
	@ [ `whoami` != "root" ] || ( echo 'Run make install as yourself, not as root.' ; exit 1 )
	mkdir -p ~/.gnome2/shotwell/plugins
	install -m 644 $(PROGRAM).so ~/.gnome2/shotwell/plugins
	install -m 444 $(ICON) ~/.gnome2/shotwell/plugins
	install -m 444 *.glade ~/.gnome2/shotwell/plugins

uninstall:
	@ [ `whoami` != "root" ] || ( echo 'Run make install as yourself, not as root.' ; exit 1 )
	rm -f ~/.gnome2/shotwell/plugins/$(PROGRAM).so

$(PROGRAM).so: $(PROGRAM).vala $(DEPS) Makefile
	valac-$(VALA_VER) -g --save-temps --main=dummy_main -X -D_VERSION='"$(VERSION)"' \
    --vapidir=$(S_DIR)/vapi/ --vapidir=$(S_PLUGIN_DIR) \
    $(foreach pkg,$(PKGS),--pkg=$(pkg)) \
    -X -I$(S_DIR) \
    -X -DGETTEXT_PACKAGE='"shotwell"' \
    -X --shared -X -fPIC $< $(DEPS) -o $@
