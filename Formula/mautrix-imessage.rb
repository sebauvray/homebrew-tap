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
  revision 4

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
  # Resend a failed message as SMS from Matrix: react with 📱 on it, or
  # `!im sms` (in reply to it, else the chat's latest failed message).
  # Messages.app has no scriptable "Send as Text Message": the text and each
  # attachment are sent again on the SMS account (Text Message Forwarding
  # through the iPhone). The SMS echo takes over the failed message's Matrix
  # event (dedup entry pointing at it, old bridge row dropped since
  # message.mxid is UNIQUE): no second message in the room. DMs with a phone
  # number only. NOT verified end to end yet: if Messages files the SMS in a
  # separate "SMS;-;+33…" chat instead of the merged "any;-;+33…", it lands
  # in a new room and the failed message is not replaced.
  patch :DATA

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

    # Report failed sends. The Mac connector treats a message as sent as soon
    # as Messages.app writes its row (the "echo"); when iMessage later refuses
    # it (red "!" in Messages, `message.error` set), nothing reaches Matrix:
    # the client keeps showing it as sent and the message silently never
    # leaves the Mac. Upstream already turns a "failed" SendMessageStatus into
    # an error notice + a permanent-failure send status, but the Mac
    # connector's MessageStatusChan() returns nil. Watch chat.db on each
    # fsevent for our own messages whose `error` became non-zero and emit it.
    inreplace "imessage/mac/database.go",
              "\tReadReceipts                 chan *imessage.ReadReceipt\n",
              "\tReadReceipts                 chan *imessage.ReadReceipt\n" \
              "\tsendFailures                 *sendFailureWatcher\n"
    inreplace "imessage/mac/messages.go" do |s|
      s.sub! "\tmac.ReadReceipts = make(chan *imessage.ReadReceipt)\n",
             "\tmac.ReadReceipts = make(chan *imessage.ReadReceipt)\n" \
             "\tmac.sendFailures = newSendFailureWatcher(mac.chatDB, mac.log)\n"
      s.sub! "func (mac *macOSDatabase) MessageStatusChan() <-chan *imessage.SendMessageStatus {\n\treturn nil\n}",
             "func (mac *macOSDatabase) MessageStatusChan() <-chan *imessage.SendMessageStatus {\n" \
             "\treturn mac.sendFailures.channel()\n}"
      s.sub! "\t\t\t\tfor _, receipt := range newReceipts {\n\t\t\t\t\tmac.ReadReceipts <- receipt\n\t\t\t\t}\n",
             "\t\t\t\tfor _, receipt := range newReceipts {\n\t\t\t\t\tmac.ReadReceipts <- receipt\n\t\t\t\t}\n" \
             "\t\t\t\tmac.sendFailures.check()\n"
    end
    (buildpath/"imessage/mac/send_failures.go").write <<~GO
      package mac

      import (
      	"database/sql"
      	"fmt"
      	"time"

      	log "maunium.net/go/maulogger/v2"

      	"go.mau.fi/mautrix-imessage/imessage"
      )

      // Own messages whose send failed (red "!" in Messages.app). Bounded by
      // ROWID (cheap range scan on the primary key) to rows written since the
      // bridge started, and by date to the last day: older failures are not
      // news, and a restart does not re-report them.
      const failedSendsQuery = `
      SELECT message.guid, chat.guid, message.error
      FROM message
      JOIN chat_message_join ON chat_message_join.message_id = message.ROWID
      JOIN chat              ON chat_message_join.chat_id = chat.ROWID
      WHERE message.ROWID > $1 AND message.is_from_me = 1 AND message.error <> 0 AND message.date > $2
      `

      const sendFailureWindow = 24 * time.Hour

      // sendFailureWatcher turns failed sends in chat.db into "failed"
      // SendMessageStatus events. A nil watcher (query could not be
      // prepared) is valid and does nothing.
      type sendFailureWatcher struct {
      	log      log.Logger
      	query    *sql.Stmt
      	minRowID int64
      	reported map[string]int64 // message GUID -> error code already reported
      	statuses chan *imessage.SendMessageStatus
      }

      func newSendFailureWatcher(db *sql.DB, logger log.Logger) *sendFailureWatcher {
      	query, err := db.Prepare(failedSendsQuery)
      	if err != nil {
      		logger.Warnln("Failed to prepare failed sends query, send failures won't be reported:", err)
      		return nil
      	}
      	var minRowID sql.NullInt64
      	if err = db.QueryRow("SELECT MAX(ROWID) FROM message").Scan(&minRowID); err != nil {
      		logger.Warnln("Failed to read last message row ID, send failures won't be reported:", err)
      		return nil
      	}
      	return &sendFailureWatcher{
      		log:      logger,
      		query:    query,
      		minRowID: minRowID.Int64,
      		reported: make(map[string]int64),
      		statuses: make(chan *imessage.SendMessageStatus, 32),
      	}
      }

      func (w *sendFailureWatcher) channel() <-chan *imessage.SendMessageStatus {
      	if w == nil {
      		return nil
      	}
      	return w.statuses
      }

      // check is called from the fsevent handler, under its lock.
      func (w *sendFailureWatcher) check() {
      	if w == nil {
      		return
      	}
      	since := time.Now().Add(-sendFailureWindow).UnixNano() - imessage.AppleEpoch.UnixNano()
      	rows, err := w.query.Query(w.minRowID, since)
      	if err != nil {
      		w.log.Warnln("Error querying failed sends:", err)
      		return
      	}
      	defer rows.Close()
      	for rows.Next() {
      		var guid, chatGUID string
      		var code int64
      		if err = rows.Scan(&guid, &chatGUID, &code); err != nil {
      			w.log.Warnln("Error scanning failed send:", err)
      			return
      		}
      		if w.reported[guid] == code {
      			continue
      		}
      		status := &imessage.SendMessageStatus{
      			GUID:       guid,
      			ChatGUID:   chatGUID,
      			Status:     "failed",
      			Service:    imessage.ParseIdentifier(chatGUID).Service,
      			StatusCode: fmt.Sprintf("%d", code),
      			Message:    "Non distribué : Messages sur le Mac n'a pas pu l'envoyer. Renvoie-le depuis Messages (en SMS si besoin).",
      		}
      		select {
      		case w.statuses <- status:
      			w.reported[guid] = code
      			w.log.Infofln("Send of %s in %s failed in Messages.app (error %d), reporting it", guid, chatGUID, code)
      		default:
      			w.log.Warnln("Message status buffer is full, will retry failed send", guid)
      		}
      	}
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

__END__
diff --git a/commands.go b/commands.go
index ee37236..66b46de 100644
--- a/commands.go
+++ b/commands.go
@@ -41,6 +41,7 @@ func (br *IMBridge) RegisterCommands() {
 		cmdPM,
 		cmdSearchContacts,
 		cmdRefreshContacts,
+		cmdResendSMS,
 	)
 }
 
diff --git a/imessage/mac/sms_resend.go b/imessage/mac/sms_resend.go
new file mode 100644
index 0000000..466ebfa
--- /dev/null
+++ b/imessage/mac/sms_resend.go
@@ -0,0 +1,101 @@
+package mac
+
+import (
+	"errors"
+	"fmt"
+	"os"
+	"path/filepath"
+	"strings"
+
+	"go.mau.fi/mautrix-imessage/imessage"
+)
+
+// Same shape as upstream's sendMessageBuddy fallback (buddy == participant,
+// service == account), but on the SMS account: the message goes through the
+// iPhone's Text Message Forwarding, like "Send as Text Message" in Messages.
+const sendTextAsSMS = `
+on run {targetHandle, messageText}
+	tell application "Messages"
+		set smsAccount to 1st account whose service type = SMS
+		set theParticipant to a reference to participant targetHandle of smsAccount
+		send messageText to theParticipant
+	end tell
+end run
+`
+
+const sendFileAsSMS = `
+on run {targetHandle, filePath}
+	tell application "Messages"
+		set smsAccount to 1st account whose service type = SMS
+		set theParticipant to a reference to participant targetHandle of smsAccount
+		send filePath as POSIX file to theParticipant
+	end tell
+end run
+`
+
+// Own failed message in a chat: the given one, or the latest one.
+const failedOwnMessageQuery = `
+SELECT message.guid FROM message
+JOIN chat_message_join ON chat_message_join.message_id = message.ROWID
+JOIN chat              ON chat_message_join.chat_id = chat.ROWID
+WHERE chat.guid = $1 AND message.is_from_me = 1 AND message.error <> 0
+  AND ($2 = '' OR message.guid = $2)
+ORDER BY message.date DESC LIMIT 1
+`
+
+var ErrNotFailed = errors.New("ce message n'est pas en échec dans Messages")
+
+// SMSResendCandidate finds the failed message to resend (messageGUID, or
+// the latest failed one when empty) and the key the echo will be matched
+// on. Nothing is sent.
+func (mac *macOSDatabase) SMSResendCandidate(chatGUID, messageGUID string) (*imessage.Message, string, error) {
+	ident := imessage.ParseIdentifier(chatGUID)
+	if ident.IsGroup {
+		return nil, "", errors.New("renvoi en SMS : discussions de groupe non prises en charge")
+	} else if !strings.HasPrefix(ident.LocalID, "+") {
+		return nil, "", errors.New("renvoi en SMS : le correspondant n'est pas un numéro de téléphone")
+	}
+	var guid string
+	if err := mac.chatDB.QueryRow(failedOwnMessageQuery, chatGUID, messageGUID).Scan(&guid); err != nil {
+		return nil, "", ErrNotFailed
+	}
+	res, err := mac.singleMessageQuery.Query(guid)
+	if err != nil {
+		return nil, "", fmt.Errorf("lecture du message %s : %w", guid, err)
+	}
+	msgs, err := mac.scanMessages(res)
+	if err != nil || len(msgs) == 0 {
+		return nil, "", fmt.Errorf("lecture du message %s : %v", guid, err)
+	}
+	msg := msgs[0] // upstream GetMessage reads msgs[1]: wrong for a single row
+	key := msg.Text
+	if len(msg.Attachments) == 1 {
+		key = msg.Attachments[0].FileName
+	}
+	return msg, strings.TrimSpace(key), nil
+}
+
+// SendAsSMS sends the message's text and attachments again, on the SMS
+// account, to the chat's phone number.
+func (mac *macOSDatabase) SendAsSMS(msg *imessage.Message) error {
+	handle := imessage.ParseIdentifier(msg.ChatGUID).LocalID
+	if strings.TrimSpace(msg.Text) != "" {
+		if err := runOsascriptWithoutOutput(sendTextAsSMS, handle, msg.Text); err != nil {
+			return fmt.Errorf("envoi du texte en SMS : %w", err)
+		}
+	}
+	for _, att := range msg.Attachments {
+		path := att.PathOnDisk
+		if strings.HasPrefix(path, "~/") {
+			home, err := os.UserHomeDir()
+			if err != nil {
+				return err
+			}
+			path = filepath.Join(home, path[2:])
+		}
+		if err := runOsascriptWithoutOutput(sendFileAsSMS, handle, path); err != nil {
+			return fmt.Errorf("envoi de %s en SMS : %w", att.FileName, err)
+		}
+	}
+	return nil
+}
diff --git a/imessage/mac/sms_resend_test.go b/imessage/mac/sms_resend_test.go
new file mode 100644
index 0000000..7d828f7
--- /dev/null
+++ b/imessage/mac/sms_resend_test.go
@@ -0,0 +1,37 @@
+package mac
+
+import (
+	"database/sql"
+	"testing"
+)
+
+func TestFailedOwnMessageQuery(t *testing.T) {
+	db, err := sql.Open("sqlite3", ":memory:")
+	if err != nil {
+		t.Fatal(err)
+	}
+	for _, q := range []string{
+		`CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, is_from_me INT, error INT, date INT)`,
+		`CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT)`,
+		`CREATE TABLE chat_message_join (chat_id INT, message_id INT)`,
+		`INSERT INTO chat VALUES (1, 'any;-;+33600000000'), (2, 'any;-;+33611111111')`,
+		`INSERT INTO message VALUES (1,'A',1,22,10),(2,'B',1,0,20),(3,'C',1,22,30),(4,'D',0,22,40),(5,'E',1,22,50)`,
+		`INSERT INTO chat_message_join VALUES (1,1),(1,2),(1,3),(1,4),(2,5)`,
+	} {
+		if _, err = db.Exec(q); err != nil {
+			t.Fatal(q, err)
+		}
+	}
+	get := func(msg string) string {
+		var guid string
+		if err := db.QueryRow(failedOwnMessageQuery, "any;-;+33600000000", msg).Scan(&guid); err != nil {
+			return "none"
+		}
+		return guid
+	}
+	for in, want := range map[string]string{"": "C", "A": "A", "B": "none", "D": "none", "E": "none"} {
+		if got := get(in); got != want {
+			t.Errorf("%q: got %s, want %s", in, got, want)
+		}
+	}
+}
diff --git a/portal.go b/portal.go
index 8afb890..071e9fc 100644
--- a/portal.go
+++ b/portal.go
@@ -229,6 +229,8 @@ func (br *IMBridge) NewPortal(dbPortal *database.Portal) *Portal {
 type SentMessage struct {
 	EventID   id.EventID
 	Timestamp time.Time
+	// ReplacesGUID: the failed message this echo (an SMS resend) replaces.
+	ReplacesGUID string
 }
 
 type Portal struct {
@@ -1510,6 +1512,9 @@ func (portal *Portal) HandleMatrixTyping(userIDs []id.UserID) {
 }
 
 func (portal *Portal) HandleMatrixReaction(evt *event.Event) {
+	if portal.handleSMSResendReaction(evt) {
+		return
+	}
 	if !portal.bridge.IM.Capabilities().SendTapbacks {
 		portal.sendUnsupportedCheckpoint(evt, status.MsgStepRemote, errors.New("reactions are not supported"))
 		return
@@ -1688,6 +1693,9 @@ func (portal *Portal) isDuplicate(dbMessage *database.Message, msg *imessage.Mes
 		if !dedup.Timestamp.Before(msg.Time) {
 			portal.log.Warnfln("Echo for Matrix message %s has lower timestamp than expected (message: %s, expected: %s)", msg.Time.Unix(), dedup.Timestamp.Unix())
 		}
+		if dedup.ReplacesGUID != "" {
+			portal.forgetReplacedMessage(dedup.ReplacesGUID)
+		}
 		dbMessage.MXID = dedup.EventID
 		dbMessage.Timestamp = msg.Time.UnixMilli()
 		dbMessage.Insert(nil)
diff --git a/sms_resend.go b/sms_resend.go
new file mode 100644
index 0000000..b9d2016
--- /dev/null
+++ b/sms_resend.go
@@ -0,0 +1,113 @@
+package main
+
+import (
+	"fmt"
+	"strings"
+	"time"
+
+	"maunium.net/go/mautrix/bridge/commands"
+	"maunium.net/go/mautrix/event"
+	"maunium.net/go/mautrix/id"
+
+	"go.mau.fi/mautrix-imessage/imessage"
+)
+
+// Connectors that can resend a failed message as SMS (the Mac one).
+type smsResender interface {
+	SMSResendCandidate(chatGUID, messageGUID string) (*imessage.Message, string, error)
+	SendAsSMS(msg *imessage.Message) error
+}
+
+// Reacting with this on a failed message resends it as SMS. Not a tapback
+// emoji (imessage.TapbackFromEmoji), so it never reaches the contact.
+const smsResendReaction = "📱"
+
+// resendAsSMS resends the failed message behind target (or, when target is
+// not a bridged message, the latest failed one of this chat). The SMS echo
+// takes over the original event: no second message appears in Matrix.
+func (portal *Portal) resendAsSMS(target id.EventID) error {
+	resender, ok := portal.bridge.IM.(smsResender)
+	if !ok {
+		return fmt.Errorf("ce connecteur ne sait pas renvoyer en SMS")
+	}
+	var messageGUID string
+	if target != "" {
+		if dbMsg := portal.bridge.DB.Message.GetByMXID(target); dbMsg != nil && dbMsg.PortalGUID == portal.GUID {
+			messageGUID = dbMsg.GUID
+		}
+	}
+	msg, key, err := resender.SMSResendCandidate(portal.GUID, messageGUID)
+	if err != nil {
+		return err
+	}
+	dbMsg := portal.bridge.DB.Message.GetLastByGUID(portal.GUID, msg.GUID)
+	if dbMsg != nil && key != "" {
+		portal.addResendDedup(dbMsg.MXID, key, msg.GUID)
+	}
+	if err = resender.SendAsSMS(msg); err != nil {
+		portal.messageDedupLock.Lock()
+		delete(portal.messageDedup, key)
+		portal.messageDedupLock.Unlock()
+		return err
+	}
+	portal.log.Infofln("Resent failed message %s as SMS", msg.GUID)
+	return nil
+}
+
+func (portal *Portal) addResendDedup(eventID id.EventID, key, oldGUID string) {
+	if portal.messageDedup == nil {
+		return
+	}
+	portal.messageDedupLock.Lock()
+	portal.messageDedup[key] = SentMessage{EventID: eventID, Timestamp: time.Now().Add(-10 * time.Second), ReplacesGUID: oldGUID}
+	portal.messageDedupLock.Unlock()
+}
+
+// forgetReplacedMessage drops the failed row so the SMS echo can take its
+// Matrix event (message.mxid is UNIQUE).
+func (portal *Portal) forgetReplacedMessage(guid string) {
+	if _, err := portal.bridge.DB.Exec("DELETE FROM message WHERE portal_guid=$1 AND guid=$2", portal.GUID, guid); err != nil {
+		portal.log.Warnfln("Failed to forget replaced message %s: %v", guid, err)
+	}
+}
+
+func (portal *Portal) sendResendNotice(text string) {
+	intent := portal.bridge.Bot
+	if !portal.Encrypted {
+		intent = portal.MainIntent()
+	}
+	_, _ = portal.sendMessage(intent, event.EventMessage, event.MessageEventContent{MsgType: event.MsgNotice, Body: text}, map[string]interface{}{}, 0)
+}
+
+// handleSMSResendReaction is called before tapback handling.
+func (portal *Portal) handleSMSResendReaction(evt *event.Event) bool {
+	reaction, ok := evt.Content.Parsed.(*event.ReactionEventContent)
+	if !ok || strings.TrimSuffix(reaction.RelatesTo.Key, "️") != smsResendReaction {
+		return false
+	}
+	if err := portal.resendAsSMS(reaction.RelatesTo.EventID); err != nil {
+		portal.sendResendNotice("⚠ Renvoi en SMS impossible : " + err.Error())
+	} else {
+		portal.sendResendNotice("📱 Renvoyé en SMS.")
+	}
+	return true
+}
+
+var cmdResendSMS = &commands.FullHandler{
+	Func: wrapCommand(fnResendSMS),
+	Name: "sms",
+	Help: commands.HelpMeta{
+		Section:     HelpSectionManagingPortals,
+		Description: "Renvoie en SMS le message en échec auquel on répond (sinon le dernier en échec).",
+	},
+	RequiresPortal: true,
+	RequiresLogin:  false,
+}
+
+func fnResendSMS(ce *WrappedCommandEvent) {
+	if err := ce.Portal.resendAsSMS(ce.ReplyTo); err != nil {
+		ce.Reply("Renvoi en SMS impossible : %s", err)
+	} else {
+		ce.Reply("📱 Renvoyé en SMS.")
+	}
+}
