#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

#include <fstream>
#include <string>
#include <vector>
#include <cstring>

// SHA-256 实现（避免外部依赖）
namespace {
struct Sha256Ctx {
  uint32_t state[8];
  uint64_t bitlen;
  uint8_t data[64];
  uint32_t datalen;
};

static const uint32_t k[64] = {
  0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
  0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
  0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
  0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
  0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
  0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
  0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
  0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
};

#define ROTR(x,n) (((x) >> (n)) | ((x) << (32-(n))))
#define EP0(x) (ROTR(x,2) ^ ROTR(x,13) ^ ROTR(x,22))
#define EP1(x) (ROTR(x,6) ^ ROTR(x,11) ^ ROTR(x,25))
#define SIG0(x) (ROTR(x,7) ^ ROTR(x,18) ^ ((x) >> 3))
#define SIG1(x) (ROTR(x,17) ^ ROTR(x,19) ^ ((x) >> 10))

void sha256_init(Sha256Ctx* ctx) {
  ctx->datalen = 0;
  ctx->bitlen = 0;
  ctx->state[0] = 0x6a09e667; ctx->state[1] = 0xbb67ae85;
  ctx->state[2] = 0x3c6ef372; ctx->state[3] = 0xa54ff53a;
  ctx->state[4] = 0x510e527f; ctx->state[5] = 0x9b05688c;
  ctx->state[6] = 0x1f83d9ab; ctx->state[7] = 0x5be0cd19;
}

void sha256_transform(Sha256Ctx* ctx, const uint8_t* data) {
  uint32_t a,b,c,d,e,f,g,h,t1,t2,m[64];
  for (int i = 0, j = 0; i < 16; i++, j += 4)
    m[i] = (data[j]<<24)|(data[j+1]<<16)|(data[j+2]<<8)|(data[j+3]);
  for (int i = 16; i < 64; i++)
    m[i] = SIG1(m[i-2]) + m[i-7] + SIG0(m[i-15]) + m[i-16];
  a=ctx->state[0];b=ctx->state[1];c=ctx->state[2];d=ctx->state[3];
  e=ctx->state[4];f=ctx->state[5];g=ctx->state[6];h=ctx->state[7];
  for (int i = 0; i < 64; i++) {
    t1 = h + EP1(e) + ((e&f)^((~e)&g)) + k[i] + m[i];
    t2 = EP0(a) + ((a&b)^(a&c)^(b&c));
    h=g;g=f;f=e;e=d+t1;d=c;c=b;b=a;a=t1+t2;
  }
  ctx->state[0]+=a;ctx->state[1]+=b;ctx->state[2]+=c;ctx->state[3]+=d;
  ctx->state[4]+=e;ctx->state[5]+=f;ctx->state[6]+=g;ctx->state[7]+=h;
}

void sha256_update(Sha256Ctx* ctx, const uint8_t* data, size_t len) {
  for (size_t i = 0; i < len; i++) {
    ctx->data[ctx->datalen++] = data[i];
    if (ctx->datalen == 64) {
      sha256_transform(ctx, ctx->data);
      ctx->bitlen += 512;
      ctx->datalen = 0;
    }
  }
}

std::vector<uint8_t> sha256_final(Sha256Ctx* ctx) {
  uint32_t i = ctx->datalen;
  if (ctx->datalen < 56) {
    ctx->data[i++] = 0x80;
    while (i < 56) ctx->data[i++] = 0;
  } else {
    ctx->data[i++] = 0x80;
    while (i < 64) ctx->data[i++] = 0;
    sha256_transform(ctx, ctx->data);
    memset(ctx->data, 0, 56);
  }
  ctx->bitlen += ctx->datalen * 8;
  ctx->data[63] = ctx->bitlen;
  ctx->data[62] = ctx->bitlen >> 8;
  ctx->data[61] = ctx->bitlen >> 16;
  ctx->data[60] = ctx->bitlen >> 24;
  ctx->data[59] = ctx->bitlen >> 32;
  ctx->data[58] = ctx->bitlen >> 40;
  ctx->data[57] = ctx->bitlen >> 48;
  ctx->data[56] = ctx->bitlen >> 56;
  sha256_transform(ctx, ctx->data);

  std::vector<uint8_t> hash(32);
  for (i = 0; i < 4; i++) {
    hash[i]    = (ctx->state[0] >> (24-i*8)) & 0xFF;
    hash[i+4]  = (ctx->state[1] >> (24-i*8)) & 0xFF;
    hash[i+8]  = (ctx->state[2] >> (24-i*8)) & 0xFF;
    hash[i+12] = (ctx->state[3] >> (24-i*8)) & 0xFF;
    hash[i+16] = (ctx->state[4] >> (24-i*8)) & 0xFF;
    hash[i+20] = (ctx->state[5] >> (24-i*8)) & 0xFF;
    hash[i+24] = (ctx->state[6] >> (24-i*8)) & 0xFF;
    hash[i+28] = (ctx->state[7] >> (24-i*8)) & 0xFF;
  }
  return hash;
}

// 从 /etc/machine-id 派生 32 字节主密钥
std::vector<uint8_t> GetMasterKeyFromMachineId() {
  std::ifstream file("/etc/machine-id");
  std::string machine_id;
  if (file) {
    std::getline(file, machine_id);
  }
  if (machine_id.empty()) {
    // 回退：/var/lib/dbus/machine-id
    std::ifstream file2("/var/lib/dbus/machine-id");
    if (file2) std::getline(file2, machine_id);
  }
  if (machine_id.empty()) {
    // 最终回退：固定值（不理想，但比源码硬编码好——至少绑定到安装）
    machine_id = "ai-terminal-fallback-key-do-not-use-in-production";
  }

  // SHA-256(machine_id + app_salt) 生成 32 字节密钥
  std::string salt = "A1Terminal::2024::LinuxMasterKey";
  Sha256Ctx ctx;
  sha256_init(&ctx);
  sha256_update(&ctx, reinterpret_cast<const uint8_t*>(machine_id.data()),
                machine_id.size());
  sha256_update(&ctx, reinterpret_cast<const uint8_t*>(salt.data()),
                salt.size());
  return sha256_final(&ctx);
}

// MethodChannel 回调：返回主密钥
// 注意：Flutter Linux SDK 3.x 要求 handler 签名为 (channel, method_call, user_data)
void security_method_call_handler(FlMethodChannel* channel,
                                  FlMethodCall* method_call,
                                  gpointer user_data) {
  const gchar* method = fl_method_call_get_name(method_call);
  if (g_strcmp0(method, "getMasterKey") == 0) {
    auto key = GetMasterKeyFromMachineId();
    g_autoptr(FlValue) result = fl_value_new_uint8_list(key.data(), key.size());
    fl_method_call_respond_success(method_call, result, nullptr);
  } else {
    fl_method_call_respond_not_implemented(method_call, nullptr);
  }
}

}  // namespace

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "ai_terminal");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "ai_terminal");
  }

  gtk_window_set_default_size(window, 1280, 720);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  // 注册安全插件（machine-id 派生主密钥）
  {
    FlBinaryMessenger* messenger = fl_engine_get_binary_messenger(
        fl_view_get_engine(view));
    g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
    g_autoptr(FlMethodChannel) channel = fl_method_channel_new(
        messenger, "com.keiskei.aiterminal/security",
        FL_METHOD_CODEC(codec));
    fl_method_channel_set_method_call_handler(
        channel, security_method_call_handler, nullptr, nullptr);
  }

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
