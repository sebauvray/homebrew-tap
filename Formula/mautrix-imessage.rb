# mautrix-imessage has no tagged releases and no official Homebrew formula.
# This formula pins a known-good commit of master and builds from source
# (the upstream CI artifacts live on mau.dev with unstable URLs, so they
# cannot be pinned by sha256).
#
# To bump: update PINNED_COMMIT + version (commit date) + sha256 of
# https://github.com/mautrix/imessage/archive/<commit>.tar.gz.
class MautrixImessage < Formula
  PINNED_COMMIT = "300ba6d0e5566d1f841d42ee1555779a9b6fa4be".freeze

  desc "Matrix <-> iMessage puppeting bridge (standard Mac connector)"
  homepage "https://github.com/mautrix/imessage"
  url "https://github.com/mautrix/imessage/archive/#{PINNED_COMMIT}.tar.gz"
  # Date of the pinned commit — keeps versions monotonic across bumps.
  version "2026.05.14"
  sha256 "7286820d1ef9642f7459581e823777f8bcf6888929666a8ab7d759c4ce5cf140"
  license "AGPL-3.0-or-later"
  revision 2

  depends_on "cmake" => :build
  depends_on "go" => :build
  # Runtime, for media conversion: macOS ships sips (HEIC->JPEG) and
  # afconvert (CAF->M4A), but nothing that converts MOV/3GP video to MP4.
  # Without ffmpeg the history importer leaves videos in a format no browser
  # plays, and does so SILENTLY — it falls back to the system tools and
  # reports no error. Declared here so the connector never installs half a
  # converter.
  depends_on "ffmpeg"
  depends_on :macos

  # mautrix-imessage pins a legacy mautrix-go (v0.16.x line) whose crypto
  # links libolm through cgo — no goolm build tag on that line. Homebrew-core
  # dropped the libolm formula (upstream olm is unmaintained), so olm is
  # vendored here and linked STATICALLY: the installed binary has no
  # runtime dependency on it.
  resource "libolm" do
    url "https://gitlab.matrix.org/matrix-org/olm/-/archive/3.2.16/olm-3.2.16.tar.gz"
    sha256 "1e90f9891009965fd064be747616da46b232086fe270b77605ec9bda34272a68"
  end

  # The upstream-optional `libheif` build tag is NOT enabled: it pins Go
  # bindings (strukturag/libheif v1.19.x) that don't compile against current
  # brew libheif headers. HEIF->JPEG conversion is disabled, same as
  # upstream's default build.

  def install
    olm_prefix = buildpath/"olm-prefix"
    resource("libolm").stage do
      # olm 3.2.16 increments a `T * const` iterator in its list template —
      # ill-formed C++ that recent clang rejects (one of the reasons
      # homebrew-core dropped the formula). One-line fix.
      inreplace "include/olm/list.hh",
                "T * const other_pos = other._data;",
                "T * other_pos = other._data;"
      args = %W[
        -DBUILD_SHARED_LIBS=OFF
        -DCMAKE_BUILD_TYPE=Release
        -DCMAKE_INSTALL_PREFIX=#{olm_prefix}
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
      ]
      system "cmake", "-S", ".", "-B", "build", *args
      system "cmake", "--build", "build"
      system "cmake", "--install", "build"
    end

    # Recent macOS (27) merges iMessage and SMS chats under the "any" service
    # (chat GUIDs "any;-;+33…"). When Messages.app has no such chat loaded,
    # `send … to chat id` fails with -1728 and the bridge falls back to
    # scripts doing `1st service whose service type = <service>` — with
    # "any", which is no AppleScript constant (-1700), so the send is lost.
    # Map "any" to iMessage for those fallbacks: the buddy lookup then works.
    inreplace "imessage/mac/send.go" do |s|
      s.gsub! "fmt.Sprintf(fallbackScript1, identifier.Service)",
              "fmt.Sprintf(fallbackScript1, scriptService(identifier.Service))"
      s.gsub! "fmt.Sprintf(fallbackScript2, identifier.Service)",
              "fmt.Sprintf(fallbackScript2, scriptService(identifier.Service))"
    end
    (buildpath/"imessage/mac/service_any.go").write <<~GO
      package mac

      // scriptService maps a chat GUID service to an AppleScript service
      // type constant: "any" (merged iMessage/SMS chats) is not one.
      func scriptService(service string) string {
      	if service == "any" {
      		return "iMessage"
      	}
      	return service
      }
    GO

    # Double puppeting through the appservice token, so the owner's own
    # messages keep their real date. Synapse honours `?ts=` only when the
    # requester IS an appservice (rest/client/room.py). Upstream, the literal
    # `login_shared_secret: appservice` does an m.login.application_service
    # login and then sends with the resulting USER token: `ts` is dropped and
    # every message caught up after an outage is dated at catch-up time
    # (contacts' messages, sent by ghosts with the AS token, keep theirs).
    # This legacy mautrix-go (v0.16) predates the `as_token:` double-puppet
    # mode of newer bridges, so add it here: with `appservice` (registration
    # token) or `as_token:<token>`, the double puppet client uses the AS token
    # + `?user_id=` and never logs in. Requires the owner to be in the
    # registration's users namespace (exclusive: false) — exactly what the
    # appservice login already required. The echo marker
    # (fi.mau.double_puppet_source, IsCustomPuppet) is untouched.
    inreplace "custompuppet.go" do |s|
      s.sub! "\tloginSecret := user.bridge.Config.Bridge.LoginSharedSecret\n",
             "\tloginSecret := user.bridge.Config.Bridge.LoginSharedSecret\n" \
             "\tif _, ok := user.masqueradeToken(); ok {\n" \
             "\t\treturn user.useMasquerade()\n" \
             "\t}\n"
      s.sub! "\tclient, err := user.bridge.AS.NewExternalMautrixClient(user.MXID, user.AccessToken, " \
             "user.bridge.Config.Bridge.DoublePuppetServerURL)\n",
             "\tclient, err := user.newDoublePuppetClient()\n"
    end
    (buildpath/"custompuppet_masquerade.go").write <<~GO
      package main

      import (
      	"strings"

      	"maunium.net/go/mautrix"
      )

      // masqueradeSentinel is stored as the user's access token in
      // masquerade mode: never a credential, only "double puppeting is
      // configured" for whoever reads the database (the history importer).
      const masqueradeSentinel = "appservice"

      // masqueradeToken returns the appservice token the double puppet acts
      // with, if login_shared_secret selects masquerade mode.
      func (user *User) masqueradeToken() (string, bool) {
      	secret := user.bridge.Config.Bridge.LoginSharedSecret
      	if secret == "appservice" {
      		return user.bridge.AS.Registration.AppToken, true
      	}
      	if token, ok := strings.CutPrefix(secret, "as_token:"); ok && token != "" {
      		return token, true
      	}
      	return "", false
      }

      // useMasquerade replaces the shared-secret login: nothing to log in to.
      func (user *User) useMasquerade() error {
      	user.log.Debugln("Double puppeting with the appservice token (masquerade, ?user_id=)")
      	if user.AccessToken != masqueradeSentinel {
      		user.AccessToken = masqueradeSentinel
      		user.Update()
      	}
      	return nil
      }

      // newDoublePuppetClient is the double puppet's Matrix client: the
      // stored user token, or in masquerade mode the appservice token with
      // ?user_id= so that Synapse honours ?ts= on caught-up messages.
      func (user *User) newDoublePuppetClient() (*mautrix.Client, error) {
      	client, err := user.bridge.AS.NewExternalMautrixClient(user.MXID, user.AccessToken, user.bridge.Config.Bridge.DoublePuppetServerURL)
      	if err != nil {
      		return nil, err
      	}
      	if token, ok := user.masqueradeToken(); ok {
      		client.AccessToken = token
      		client.SetAppServiceUserID = true
      	}
      	return client, nil
      }
    GO

    ENV.append "CGO_CFLAGS", "-I#{olm_prefix}/include"
    ENV.append "CGO_LDFLAGS", "-L#{olm_prefix}/lib"
    ldflags = "-X main.Commit=#{PINNED_COMMIT} -X main.Tag=v#{version}"
    system "go", "build", *std_go_args(ldflags:)
    # Shipped so config generators can start from the exact example that
    # matches this build, instead of fetching one from master.
    pkgshare.install "example-config.yaml"
  end

  # `brew services start mautrix-imessage` installs a user LaunchAgent with
  # KeepAlive, so the bridge survives crashes and logs out of the box. The
  # config/working dir is a fixed per-user prefix; whoever provisions the
  # bridge must create it and write config.yaml before starting the service.
  service do
    run [opt_bin/"mautrix-imessage", "-c", "#{Dir.home}/Library/Application Support/mautrix-imessage/config.yaml"]
    keep_alive true
    working_dir "#{Dir.home}/Library/Application Support/mautrix-imessage"
    log_path "#{Dir.home}/Library/Application Support/mautrix-imessage/logs/stdout.log"
    error_log_path "#{Dir.home}/Library/Application Support/mautrix-imessage/logs/stderr.log"
  end

  test do
    # -g generates the appservice registration from a config — exercises the
    # real binary end to end without needing iMessage or a homeserver. The
    # bridge refuses placeholder example.com values, so swap in test ones.
    cp pkgshare/"example-config.yaml", testpath/"config.yaml"
    inreplace testpath/"config.yaml" do |s|
      s.gsub! "domain: example.com", "domain: matrix.test"
      s.gsub! "address: https://matrix.example.com", "address: https://matrix.test"
      s.gsub! 'user: "@you:example.com"', 'user: "@tester:matrix.test"'
    end
    system bin/"mautrix-imessage", "-g",
           "-c", testpath/"config.yaml",
           "-r", testpath/"registration.yaml"
    assert_path_exists testpath/"registration.yaml"
    assert_match "as_token", (testpath/"registration.yaml").read
  end
end
