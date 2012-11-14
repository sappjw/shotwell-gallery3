/* Copyright 2012 Joe Sapp nixphoeni@gentoo.org
 *
 * This software is licensed under the GNU LGPL (version 2.1 or later).
 * See the COPYING file in this distribution.
 */


extern const string _VERSION;

// This module's Spit.Module
private class ShotwellPublishingGallery3 : Object, Spit.Module {
    private Spit.Pluggable[] pluggables = new Spit.Pluggable[0];

    public ShotwellPublishingGallery3(GLib.File module_file) {
        GLib.File resource_directory = module_file.get_parent();

        pluggables += new Gallery3Service(resource_directory);
    }

    public unowned string get_module_name() {
        return _("Gallery3 publishing module");
    }

    public unowned string get_version() {
        return _VERSION;
    }

    public unowned string get_id() {
        return "org.yorba.shotwell.publishing.modulegallery3";
    }

    public unowned Spit.Pluggable[]? get_pluggables() {
        return pluggables;
    }
}

// This entry point is required for all SPIT modules.
public Spit.Module? spit_entry_point(Spit.EntryPointParams *params) {
    params->module_spit_interface = Spit.negotiate_interfaces(params->host_min_spit_interface,
        params->host_max_spit_interface, Spit.CURRENT_INTERFACE);

    return (params->module_spit_interface != Spit.UNSUPPORTED_INTERFACE)
        ? new ShotwellPublishingGallery3(params->module_file) : null;
}

// The Pluggable
public class Gallery3Service : Object, Spit.Pluggable, Spit.Publishing.Service {
    private const string ICON_FILENAME = "gallery3.png";

    private static Gdk.Pixbuf[] icon_pixbuf_set = null;

    public Gallery3Service(GLib.File resource_directory) {
        if (icon_pixbuf_set == null)
            icon_pixbuf_set = Resources.load_icon_set(resource_directory.get_child(ICON_FILENAME));
    }

    public int get_pluggable_interface(int min_host_interface, int max_host_interface) {
        return Spit.negotiate_interfaces(min_host_interface, max_host_interface,
            Spit.Publishing.CURRENT_INTERFACE);
    }

    public unowned string get_id() {
        return "org.yorba.shotwell.publishing.gallery3";
    }

    public unowned string get_pluggable_name() {
        return "Gallery3";
    }

    public void get_info(out Spit.PluggableInfo info) {
        info.authors = "Joe Sapp";
        info.copyright = "2012 Joe Sapp";
        info.translators = Resources.TRANSLATORS;
        info.version = _VERSION;
        //info.website_name = Resources.WEBSITE_NAME;
        //info.website_url = Resources.WEBSITE_URL;
        info.is_license_wordwrapped = false;
        info.license = Resources.LICENSE;
        info.icons = icon_pixbuf_set;
    }

    public void activation(bool enabled) {
    }

    public Spit.Publishing.Publisher create_publisher(Spit.Publishing.PluginHost host) {
        return new Publishing.Gallery3.GalleryPublisher(this, host);
    }

    public Spit.Publishing.Publisher.MediaType get_supported_media() {
        return (Spit.Publishing.Publisher.MediaType.PHOTO |
            Spit.Publishing.Publisher.MediaType.VIDEO);
    }
}


namespace Publishing.Gallery3 {
private const string SERVICE_NAME = "Gallery3";
private const string SERVICE_WELCOME_MESSAGE =
    _("You are not currently logged into your Gallery.\n\nYou must have already signed up for a Gallery3 account to complete the login process.");
private const string DEFAULT_ALBUM_DIR = _("Shotwell");
private const string DEFAULT_ALBUM_TITLE = _("Shotwell default directory");
private const string CONFIG_NAME = "gallery3";

private struct AlbumPerms {
    bool add;
    bool write;
    bool del_alb;
    bool create_sub;
}

private struct AlbumInfo {
    string extrafields;
}

private class Album {
    /* info from GalleryWeb */
    public string title;
    public string name;
    public string summary;
    public string  parentname;
    public AlbumPerms perms;
    public AlbumInfo  info ;


    public Album() {
    }
}

private class BaseGalleryTransaction : Publishing.RESTSupport.Transaction {

    protected Json.Parser parser;

    // BaseGalleryTransaction constructor
    public BaseGalleryTransaction(Session session, string endpoint_url,
            string item_path = "",
            Publishing.RESTSupport.HttpMethod method =
            Publishing.RESTSupport.HttpMethod.POST) {

        string prefix = "";

        if ((item_path != "") && (item_path[0] != '/')) {
            warning("Bad item path, this is a bug!");
            prefix = "/";
        }

        base.with_endpoint_url(session,
            endpoint_url + "/index.php/rest" + prefix + item_path,
            method);

        this.parser = new Json.Parser();

    }

}

private class KeyFetchTransaction : BaseGalleryTransaction {

    private string key = "";

    // KeyFetchTransaction constructor
    //
    // url: Base gallery URL
    public KeyFetchTransaction(Session session, string url, string username, string password) {
        // TODO: check if URL is properly formed...?
        if (url[0:4] == "http") {
            base(session, url);
            add_argument("user", username);
            add_argument("password", password);
        }
        else {
            debug("ERROR: bad URL");
        }
    }

    public string get_key() throws Spit.Publishing.PublishingError {

        string json_object;

        if (key != "")
            return key;

        json_object = get_response();

        if (json_object == null || json_object.length == 0)
            throw new Spit.Publishing.PublishingError.MALFORMED_RESPONSE(
                "No response data from %s", get_endpoint_url());

        // The returned data isn't actually a JSON object...
        json_object = "{\"key\": " + json_object + "}";
        debug("json_object: %s", json_object);

        try {
            this.parser.load_from_data(json_object);
        }
        catch (GLib.Error e) {
            // If this didn't work, reset the "executed" state
            debug("ERROR: didn't load JSON data");
            set_is_executed(false);
            throw new Spit.Publishing.PublishingError.PROTOCOL_ERROR(e.message);
        }

        unowned Json.Node root_node = parser.get_root();
        if (root_node.is_null())
            throw new Spit.Publishing.PublishingError.MALFORMED_RESPONSE(
                "Root node is null, doesn't appear to be JSON data");
        else
            this.key = root_node.get_object().get_string_member("key");

        return this.key;
    }

    public void forget_key() {
        key = "";
    }

}
}


public class GalleryPublisher : Spit.Publishing.Publisher, GLib.Object {
    private weak Spit.Publishing.PluginHost host = null;
    private Spit.Publishing.ProgressCallback progress_reporter = null;
    private weak Spit.Publishing.Service service = null;
    private Session session = null;
    private bool running = false;
    private Album[] albums = null;
    private Spit.Publishing.Publisher.MediaType media_type =
      Spit.Publishing.Publisher.MediaType.NONE;
    private string key = null;

    public GalleryPublisher(Spit.Publishing.Service service,
        Spit.Publishing.PluginHost host) {
        this.service = service;
        this.host = host;
        this.session = new Session();

        // Ticket #3212 - Only display the size chooser if we're uploading a
        // photograph, since resizing of video isn't supported.
        //
        // Find the media types involved. We need this to decide whether
        // to show the size combobox or not.
        foreach(Spit.Publishing.Publishable p in host.get_publishables()) {
            media_type |= p.get_media_type();
        }
    }

    public bool is_running() {
        return running;
    }

    public Spit.Publishing.Service get_service() {
        return service;
    }

    public void start() {
        if (is_running())
            return;

        if (host == null)
            error("GalleryPublisher: start( ): can't start; this " +
              "publisher is not restartable.");

        debug("GalleryPublisher: starting interaction.");

        running = true;

        do_show_service_welcome_pane();
    }

    public void stop() {
        debug("GalleryPublisher: stop( ) invoked.");

        running = false;
    }

    // Config getters/setters
    // API key
    internal string? get_api_key() {
        return host.get_config_string("api-key", null);
    }

    internal void set_api_key(string key) {
        host.set_config_string("api-key", key);
    }

    // URL
    internal string? get_gallery_url() {
        return host.get_config_string("url", null);
    }

    internal void set_gallery_url(string url) {
        host.set_config_string("url", url);
    }

    // Username
    internal string? get_gallery_username() {
        return host.get_config_string("username", null);
    }

    internal void set_gallery_username(string username) {
        host.set_config_string("username", username);
    }

    internal bool? get_persistent_strip_metadata() {
        return false;
    }

    internal void set_persistent_strip_metadata(bool strip_metadata) {
    }

    // Pane installation functions
    private void do_show_service_welcome_pane() {
        debug("ACTION: showing service welcome pane.");

        host.install_welcome_pane(SERVICE_WELCOME_MESSAGE,
          on_service_welcome_login);
    }

    private void do_show_credentials_pane(CredentialsPane.Mode mode) {
        debug("ACTION: showing credentials capture pane in %s mode.",
          mode.to_string());

        CredentialsPane creds_pane =
            new CredentialsPane(host, mode, get_gallery_url(),
                get_gallery_username());
        creds_pane.go_back.connect(on_credentials_go_back);
        creds_pane.login.connect(on_credentials_login);

        host.install_dialog_pane(creds_pane);
    }

    private void do_network_login(string url, string username, string password) {
        debug("ACTION: attempting network login for user '%s' at URL " +
            "'%s'.", username, url);

        host.install_login_wait_pane();

        KeyFetchTransaction fetch_trans =
            new KeyFetchTransaction(session, url, username, password);
        fetch_trans.network_error.connect(on_key_fetch_error);
        fetch_trans.completed.connect(on_key_fetch_complete);

        try {
            fetch_trans.execute();
        } catch (Spit.Publishing.PublishingError err) {
            // 403 errors are recoverable, so don't post the error to
            // our host immediately; instead, try to recover from it
            on_key_fetch_error(fetch_trans, err);
        }
    }

    private void do_show_publishing_options_pane(string url,
            string username) {
        debug("ACTION: showing publishing options pane");

        Gtk.Builder builder = new Gtk.Builder();

        try {
            builder.add_from_file(
                host.get_module_file().get_parent().get_child(
                    "gallery3_publishing_options_pane.glade").get_path());
        }
        catch (Error e) {
            warning("Could not parse UI file! Error: %s.", e.message);
            host.post_error(
                new Spit.Publishing.PublishingError.LOCAL_FILE_ERROR(
                    _("A file required for publishing is unavailable. Publishing to Gallery3 can't continue.")));
            return;
        }

        PublishingOptionsPane pane =
            new PublishingOptionsPane(host, url, username, albums,
                builder, get_persistent_strip_metadata());
        pane.publish.connect(on_publishing_options_pane_publish);
        pane.logout.connect(on_publishing_options_pane_logout);
        host.install_dialog_pane(pane);
    }

    // Callbacks
    private void on_service_welcome_login() {
        if (!is_running())
            return;

        debug("EVENT: user clicked 'Login' in welcome pane.");

        do_show_credentials_pane(CredentialsPane.Mode.INTRO);
    }

    private void on_credentials_login(string url, string username,
            string password) {
        if (!is_running())
            return;

        debug("EVENT: user '%s' clicked 'Login' in credentials pane.",
          username);

        set_gallery_url(url);
        set_gallery_username(username);
        do_network_login(url, username, password);
    }

    private void on_credentials_go_back() {
        if (!is_running())
            return;

        debug("EVENT: user is attempting to go back.");

        do_show_service_welcome_pane();
    }

    private void on_key_fetch_error(Publishing.RESTSupport.Transaction bad_txn,
            Spit.Publishing.PublishingError err) {
        bad_txn.completed.disconnect(on_key_fetch_complete);
        bad_txn.network_error.disconnect(on_key_fetch_error);

        if (!is_running())
            return;

        // ignore these events if the session is already auth'd
        if (session.is_authenticated())
            return;

        debug("EVENT: network transaction to fetch key for login " +
            "failed; response = '%s'.",
            bad_txn.get_response());

        // HTTP error 403 is invalid authentication -- if we get this
        // error during key fetch then we can just show the login screen
        // again with a retry message; if we get any error other than
        // 403 though, we can't recover from it, so just post the error
        // to the user
        if (bad_txn.get_status_code() == 403) {
            do_show_credentials_pane(CredentialsPane.Mode.FAILED_RETRY);
        }
        else {
            host.post_error(err);
        }
    }

    private void on_key_fetch_complete(Publishing.RESTSupport.Transaction txn) {
        txn.completed.disconnect(on_key_fetch_complete);
        txn.network_error.disconnect(on_key_fetch_error);

        if (!is_running())
            return;

        // ignore these events if the session is already auth'd
        if (session.is_authenticated())
            return;

        key = (txn as KeyFetchTransaction).get_key();
        if (key == null) debug("Oh noes!");
        else {
            string url = get_gallery_url();
            string username = get_gallery_username();

            debug("EVENT: network transaction to fetch key completed " +
                  "successfully (%s).", key);

            set_api_key(key);
            session.authenticate(url, username, key);
            do_show_publishing_options_pane(url, username);
        }
    }

    private void on_publishing_options_pane_logout() {
        if (!is_running())
            return;

        debug("EVENT: user is attempting to log out.");

        session.deauthenticate();
        do_show_service_welcome_pane();
    }

    private void on_publishing_options_pane_publish(PublishingParameters parameters, bool strip_metadata) {
        if (!is_running())
            return;

        debug("EVENT: user is attempting to publish something.");
    }

}

internal class PublishingOptionsPane : Spit.Publishing.DialogPane, GLib.Object {
    private const string DEFAULT_ALBUM_NAME = "";
    private const string LAST_ALBUM_CONFIG_KEY = "last-album";

    private Gtk.Builder builder = null;

    private Gtk.Grid pane_widget = null;
    private Gtk.Label title_label = null;
    private Gtk.RadioButton use_existing_radio = null;
    private Gtk.ComboBoxText existing_albums_combo = null;
    private Gtk.RadioButton create_new_radio = null;
    private Gtk.Entry new_album_entry = null;
    private Gtk.CheckButton strip_metadata_check = null;
    private Gtk.Button publish_button = null;
    private Gtk.Button logout_button = null;

    private Album[] albums;
    private string username;
    private weak Spit.Publishing.PluginHost host;

    public signal void publish(PublishingParameters parameters,
        bool strip_metadata);
    public signal void logout();

    public PublishingOptionsPane(Spit.Publishing.PluginHost host,
            string url, string username, Album[] albums,
            Gtk.Builder builder, bool strip_metadata) {
        this.username = username;
        this.albums = albums;
        this.host = host;

        this.builder = builder;
        assert(builder != null);
        assert(builder.get_objects().length() > 0);

        // pull in all widgets from builder
        pane_widget = builder.get_object("pane_widget") as Gtk.Grid;
        title_label = builder.get_object("title_label") as Gtk.Label;
        use_existing_radio = builder.get_object("publish_to_existing_radio") as Gtk.RadioButton;
        existing_albums_combo = builder.get_object("existing_albums_combo") as Gtk.ComboBoxText;
        create_new_radio = builder.get_object("publish_new_radio") as Gtk.RadioButton;
        new_album_entry = builder.get_object("new_album_name") as Gtk.Entry;
        strip_metadata_check = this.builder.get_object("strip_metadata_check") as Gtk.CheckButton;
        publish_button = builder.get_object("publish_button") as Gtk.Button;
        logout_button = builder.get_object("logout_button") as Gtk.Button;

        // populate any widgets whose contents are
        // programmatically-generated
        title_label.set_label(
            _("Publishing to %s as %s.").printf(url, username));
        strip_metadata_check.set_active(strip_metadata);


        // connect all signals.
        use_existing_radio.clicked.connect(on_use_existing_radio_clicked);
        create_new_radio.clicked.connect(on_create_new_radio_clicked);
        new_album_entry.changed.connect(on_new_album_entry_changed);
        logout_button.clicked.connect(on_logout_clicked);
        publish_button.clicked.connect(on_publish_clicked);
    }

    private void on_publish_clicked() {
        string album_name;
        if (create_new_radio.get_active()) {
            album_name = new_album_entry.get_text();
            host.set_config_string(LAST_ALBUM_CONFIG_KEY, album_name);
            publish(new PublishingParameters.to_new_album(album_name),
                strip_metadata_check.get_active());
        } else {
            album_name = albums[existing_albums_combo.get_active()].name;
            host.set_config_string(LAST_ALBUM_CONFIG_KEY, album_name);
            string album_url = albums[existing_albums_combo.get_active()].url;
            publish(new PublishingParameters.to_existing_album(album_url),
                strip_metadata_check.get_active());
        }
    }

    private void on_use_existing_radio_clicked() {
        existing_albums_combo.set_sensitive(true);
        new_album_entry.set_sensitive(false);
        existing_albums_combo.grab_focus();
        update_publish_button_sensitivity();
    }

    private void on_create_new_radio_clicked() {
        new_album_entry.set_sensitive(true);
        existing_albums_combo.set_sensitive(false);
        new_album_entry.grab_focus();
        update_publish_button_sensitivity();
    }

    private void on_logout_clicked() {
        logout();
    }

    private void update_publish_button_sensitivity() {
        string album_name = new_album_entry.get_text();
        publish_button.set_sensitive(!(album_name.strip() == "" &&
            create_new_radio.get_active()));
    }

    private void on_new_album_entry_changed() {
        update_publish_button_sensitivity();
    }

    public void installed() {
        int default_album_id = -1;
        string last_album = host.get_config_string(LAST_ALBUM_CONFIG_KEY, "");
        for (int i = 0; i < albums.length; i++) {
            existing_albums_combo.append_text(albums[i].name);
            if (albums[i].name == last_album ||
                (albums[i].name == DEFAULT_ALBUM_NAME && default_album_id == -1))
                default_album_id = i;
        }

        if (albums.length == 0) {
            existing_albums_combo.set_sensitive(false);
            use_existing_radio.set_sensitive(false);
            create_new_radio.set_active(true);
            new_album_entry.grab_focus();
            new_album_entry.set_text(DEFAULT_ALBUM_NAME);
        } else {
            if (default_album_id >= 0) {
                use_existing_radio.set_active(true);
                existing_albums_combo.set_active(default_album_id);
                new_album_entry.set_sensitive(false);
            } else {
                create_new_radio.set_active(true);
                existing_albums_combo.set_active(0);
                new_album_entry.set_text(DEFAULT_ALBUM_NAME);
                new_album_entry.grab_focus();
            }
        }
        update_publish_button_sensitivity();
    }

    protected void notify_publish(PublishingParameters parameters) {
        publish(parameters, strip_metadata_check.get_active());
    }

    protected void notify_logout() {
        logout();
    }

    public Gtk.Widget get_widget() {
        return pane_widget;
    }

    public Spit.Publishing.DialogPane.GeometryOptions get_preferred_geometry() {
        return Spit.Publishing.DialogPane.GeometryOptions.NONE;
    }

    public void on_pane_installed() {
        installed();

        publish.connect(notify_publish);
        logout.connect(notify_logout);
    }

    public void on_pane_uninstalled() {
        publish.disconnect(notify_publish);
        logout.disconnect(notify_logout);
    }
}

internal class PublishingParameters {
    private string album_name;
    private string album_url;
    private bool album_public;

    private PublishingParameters() {
    }

    public PublishingParameters.to_new_album(string album_name) {
        this.album_name = album_name;
    }

    public PublishingParameters.to_existing_album(string album_url) {
        this.album_url = album_url;
    }

    public bool is_to_new_album() {
        return (album_name != null);
    }

    public string get_album_name() {
        assert(is_to_new_album());
        return album_name;
    }

    public string get_album_entry_url() {
        assert(!is_to_new_album());
        return album_url;
    }

    // converts a publish-to-new-album parameters object into a publish-to-existing-album
    // parameters object
    public void convert(string album_url) {
        assert(is_to_new_album());

        // debug("converting publishing parameters: album '%s' has url '%s'.", album_name, album_url);

        album_name = null;
        this.album_url = album_url;
    }
}

internal class CredentialsPane : Spit.Publishing.DialogPane, GLib.Object {
    public enum Mode {
        INTRO,
        FAILED_RETRY,
        NOT_GALLERY_URL;

        public string to_string() {
            switch (this) {
                case Mode.INTRO:
                    return "INTRO";

                case Mode.FAILED_RETRY:
                    return "FAILED_RETRY";

                case Mode.NOT_GALLERY_URL:
                    return "NOT_GALLERY_URL";

                default:
                    error("unrecognized CredentialsPane.Mode enumeration value");
            }
        }
    }

    private CredentialsGrid frame = null;

    public signal void go_back();
    public signal void login(string url, string uname, string password);

    public CredentialsPane(Spit.Publishing.PluginHost host,
            Mode mode = Mode.INTRO,
            string? url = null, string? username = null) {
        frame = new CredentialsGrid(host, mode, url, username);
    }

    protected void notify_go_back() {
        go_back();
    }

    protected void notify_login(string url, string uname, string password) {
        login(url, uname, password);
    }

    public Gtk.Widget get_widget() {
        return frame;
    }

    public Spit.Publishing.DialogPane.GeometryOptions get_preferred_geometry() {
        return Spit.Publishing.DialogPane.GeometryOptions.NONE;
    }

    public void on_pane_installed() {
        frame.go_back.connect(notify_go_back);
        frame.login.connect(notify_login);

        frame.installed();
    }

    public void on_pane_uninstalled() {
        frame.go_back.disconnect(notify_go_back);
        frame.login.disconnect(notify_login);
    }
}

internal class CredentialsGrid : Gtk.Grid {
    private const string INTRO_MESSAGE = _("Enter the URL for your Gallery3 site and the username and password for your Gallery3 account.");
    private const string FAILED_RETRY_MESSAGE = _("Your Gallery didn't recognize the username and password you entered. To try again, re-enter your username and password below.");
    private const string NOT_GALLERY_URL_MESSAGE = _("The URL entered does not appear to be the main directory of a Gallery3 instance. Please make sure you typed it correctly and it does not have any trailing components (e.g., index.php).");

    private const int UNIFORM_ACTION_BUTTON_WIDTH = 102;
    private const int VERTICAL_SPACE_HEIGHT = 32;
    public const int STANDARD_CONTENT_LABEL_WIDTH = 500;

    private weak Spit.Publishing.PluginHost host = null;
    private Gtk.Entry username_entry;
    private Gtk.Entry password_entry;
    private Gtk.Entry url_entry;
    private Gtk.Entry key_entry;
    private Gtk.Button login_button;
    private Gtk.Button go_back_button;
    private string? url = null;
    private string? username = null;

    public signal void go_back();
    public signal void login(string url, string username, string password);

    public CredentialsGrid(Spit.Publishing.PluginHost host,
            CredentialsPane.Mode mode = CredentialsPane.Mode.INTRO,
            string? url = null, string? username = null) {
        this.host = host;
        this.url = url;
        this.username = username;

        // Set inter-child spacing and alignment for this grid
        set_row_spacing(60);
        set_valign(Gtk.Align.CENTER);

        // Intro message
        Gtk.Label intro_message_label = new Gtk.Label("");
        intro_message_label.set_line_wrap(true);
        attach(intro_message_label, 0, 0, 5, 1);
        intro_message_label.set_size_request(STANDARD_CONTENT_LABEL_WIDTH, -1);
        intro_message_label.set_halign(Gtk.Align.CENTER);
        intro_message_label.set_valign(Gtk.Align.CENTER);
        intro_message_label.set_hexpand(true);
        switch (mode) {
            case CredentialsPane.Mode.INTRO:
                intro_message_label.set_text(INTRO_MESSAGE);
            break;

            case CredentialsPane.Mode.FAILED_RETRY:
                intro_message_label.set_markup("<b>%s</b>\n\n%s".printf(_(
                    "Unrecognized User"), FAILED_RETRY_MESSAGE));
            break;

            case CredentialsPane.Mode.NOT_GALLERY_URL:
                intro_message_label.set_markup("<b>%s</b>\n\n%s".printf(_("Gallery3 Site Not Found"),
                    NOT_GALLERY_URL_MESSAGE));
            break;
        }

        // Labels for the entry items
        // Put in a grid for different inter-row spacing
        Gtk.Grid entry_widgets_grid = new Gtk.Grid();
        entry_widgets_grid.set_row_spacing(20);
        entry_widgets_grid.set_column_spacing(10);
        entry_widgets_grid.set_halign(Gtk.Align.CENTER);
        entry_widgets_grid.set_valign(Gtk.Align.CENTER);
        // URL
        Gtk.Label url_entry_label = new Gtk.Label.with_mnemonic(_("_URL:"));
        url_entry_label.set_halign(Gtk.Align.START);
        url_entry_label.set_valign(Gtk.Align.CENTER);
        url_entry_label.set_hexpand(true);
        url_entry_label.set_vexpand(true);
        // User name
        Gtk.Label username_entry_label = new Gtk.Label.with_mnemonic(_("User _name:"));
        username_entry_label.set_halign(Gtk.Align.START);
        username_entry_label.set_valign(Gtk.Align.CENTER);
        username_entry_label.set_hexpand(true);
        username_entry_label.set_vexpand(true);
        // Password
        Gtk.Label password_entry_label = new Gtk.Label.with_mnemonic(_("_Password:"));
        password_entry_label.set_halign(Gtk.Align.START);;
        password_entry_label.set_valign(Gtk.Align.CENTER);;
        password_entry_label.set_hexpand(true);
        password_entry_label.set_vexpand(true);

        // Entry items
        // URL
        url_entry = new Gtk.Entry();
        if (url != null)
            url_entry.set_text(url);
        url_entry.changed.connect(on_url_or_username_changed);
        url_entry.set_hexpand(true);
        url_entry.set_vexpand(true);
        url_entry.set_halign(Gtk.Align.FILL);
        url_entry.set_valign(Gtk.Align.FILL);
        // User name
        username_entry = new Gtk.Entry();
        if (username != null)
            username_entry.set_text(username);
        username_entry.changed.connect(on_url_or_username_changed);
        username_entry.set_hexpand(true);
        username_entry.set_vexpand(true);
        username_entry.set_halign(Gtk.Align.FILL);
        username_entry.set_valign(Gtk.Align.FILL);
        // Password
        password_entry = new Gtk.Entry();
        password_entry.set_visibility(false);
        password_entry.set_hexpand(true);
        password_entry.set_vexpand(true);
        password_entry.set_halign(Gtk.Align.FILL);
        password_entry.set_valign(Gtk.Align.FILL);

        // Arrange the sub-grid containing the entry items
        entry_widgets_grid.attach(url_entry_label, 0, 0, 1, 1);
        entry_widgets_grid.attach(username_entry_label, 2, 1, 1, 1);
        entry_widgets_grid.attach(password_entry_label, 2, 2, 1, 1);
        entry_widgets_grid.attach(url_entry, 1, 0, 4, 1);
        entry_widgets_grid.attach(username_entry, 3, 1, 1, 1);
        entry_widgets_grid.attach(password_entry, 3, 2, 1, 1);

        // Buttons
        go_back_button = new Gtk.Button.with_mnemonic(_("Go _Back"));
        go_back_button.clicked.connect(on_go_back_button_clicked);
        go_back_button.set_hexpand(true);
        go_back_button.set_vexpand(true);
        go_back_button.set_valign(Gtk.Align.CENTER);
        go_back_button.set_halign(Gtk.Align.START);
        go_back_button.set_size_request(UNIFORM_ACTION_BUTTON_WIDTH, -1);
        login_button = new Gtk.Button.with_mnemonic(_("_Login"));
        login_button.clicked.connect(on_login_button_clicked);
        login_button.set_sensitive((url != null) && (username != null));
        login_button.set_hexpand(true);
        login_button.set_vexpand(true);
        login_button.set_valign(Gtk.Align.CENTER);
        login_button.set_halign(Gtk.Align.END);
        login_button.set_size_request(UNIFORM_ACTION_BUTTON_WIDTH, -1);
        entry_widgets_grid.attach(go_back_button, 1, 3, 1, 1);
        entry_widgets_grid.attach(login_button, 3, 3, 1, 1);
        attach(entry_widgets_grid, 0, 1, 5, 4);

        url_entry_label.set_mnemonic_widget(url_entry);
        username_entry_label.set_mnemonic_widget(username_entry);
        password_entry_label.set_mnemonic_widget(password_entry);
    }

    private void on_login_button_clicked() {
        login(url_entry.get_text(), username_entry.get_text(), password_entry.get_text());
    }

    private void on_go_back_button_clicked() {
        go_back();
    }

    private void on_url_or_username_changed() {
        login_button.set_sensitive((url_entry.get_text() != "") && (username_entry.get_text() != ""));
    }

    public void installed() {
        host.set_service_locked(false);

        url_entry.grab_focus();
        username_entry.set_activates_default(true);
        password_entry.set_activates_default(true);
        login_button.can_default = true;
        host.set_dialog_default_widget(login_button);
    }
}

internal class Session : Publishing.RESTSupport.Session {
    private string? url = null;
    private string? username = null;
    private string? key = null;

    public Session() {
    }

    public override bool is_authenticated() {
        return (key != null);
    }

    public void authenticate(string gallery_url, string username, string key) {
        this.url = gallery_url;
        this.username = username;
        this.key = key;

        notify_authenticated();
    }

    public void deauthenticate() {
        url = null;
        username = null;
        key = null;
    }

    public string get_username() {
        return username;
    }

    public string get_url() {
        return url;
    }

    public string get_key() {
        return key;
    }

}

}

// valac wants a default entry point, so valac gets a default entry point
private void dummy_main() {
}
// vi:ts=4:sw=4:et
