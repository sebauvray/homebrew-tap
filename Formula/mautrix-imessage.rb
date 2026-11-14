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
  revision 1

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
