// LD_PRELOAD shim for xfreerdp3: shrinks the remote (Windows) mouse pointer.
//
// Why: on a scaled monitor with xwayland:force_zero_scaling, XWayland windows
// draw in real pixels but Hyprland still blows up every X cursor by the
// monitor scale. Windows already sends its pointer at its own DPI (64 px at
// 200%), so it ends up scaled twice and looks huge. Dividing the cursor image
// by the monitor scale before XWayland sees it cancels the second scaling.
//
// Only XcursorImageLoadCursor is wrapped, and only when
// RDP_LAUNCHER_CURSOR_SCALE is set to a value above 1 (e.g. "2" or "1.5").
//
// Build: gcc -O2 -shared -fPIC -o cursor-shim.so cursor-shim.c -ldl -lXcursor -lm

#define _GNU_SOURCE
#include <X11/Xcursor/Xcursor.h>
#include <dlfcn.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef Cursor (*load_fn)(Display*, const XcursorImage*);

static double cursor_scale(void) {
  static double scale = -1.0;
  if (scale < 0) {
    const char* env = getenv("RDP_LAUNCHER_CURSOR_SCALE");
    scale = env ? strtod(env, NULL) : 1.0;
    if (!(scale >= 1.0 && scale <= 4.0)) scale = 1.0;
  }
  return scale;
}

Cursor XcursorImageLoadCursor(Display* dpy, const XcursorImage* image) {
  static load_fn real = NULL;
  if (!real) real = (load_fn)dlsym(RTLD_NEXT, "XcursorImageLoadCursor");
  if (!real) return None;

  const double s = cursor_scale();
  if (s <= 1.0 || !image || !image->pixels || image->width < 2 || image->height < 2)
    return real(dpy, image);

  const int sw = (int)image->width, sh = (int)image->height;
  int dw = (int)lround(sw / s), dh = (int)lround(sh / s);
  if (dw < 1) dw = 1;
  if (dh < 1) dh = 1;

  XcursorImage* out = XcursorImageCreate(dw, dh);
  if (!out) return real(dpy, image);

  // Box filter over each destination pixel's source area, per channel.
  for (int y = 0; y < dh; y++) {
    int y0 = (int)floor(y * s), y1 = (int)ceil((y + 1) * s);
    if (y1 > sh) y1 = sh;
    if (y1 <= y0) y1 = y0 + 1;
    for (int x = 0; x < dw; x++) {
      int x0 = (int)floor(x * s), x1 = (int)ceil((x + 1) * s);
      if (x1 > sw) x1 = sw;
      if (x1 <= x0) x1 = x0 + 1;
      uint32_t acc[4] = {0, 0, 0, 0}, n = 0;
      for (int yy = y0; yy < y1; yy++)
        for (int xx = x0; xx < x1; xx++) {
          uint32_t p = image->pixels[yy * sw + xx];
          acc[0] += (p >> 24) & 0xff;
          acc[1] += (p >> 16) & 0xff;
          acc[2] += (p >> 8) & 0xff;
          acc[3] += p & 0xff;
          n++;
        }
      out->pixels[y * dw + x] = ((acc[0] / n) << 24) | ((acc[1] / n) << 16) |
                                ((acc[2] / n) << 8) | (acc[3] / n);
    }
  }

  int xh = (int)lround(image->xhot / s), yh = (int)lround(image->yhot / s);
  out->xhot = xh < dw ? xh : dw - 1;
  out->yhot = yh < dh ? yh : dh - 1;
  out->delay = image->delay;

  if (getenv("RDP_LAUNCHER_CURSOR_DEBUG"))
    fprintf(stderr, "cursor-shim: %dx%d hot %d,%d -> %dx%d hot %d,%d\n", sw, sh,
            (int)image->xhot, (int)image->yhot, dw, dh, (int)out->xhot, (int)out->yhot);

  Cursor cursor = real(dpy, out);
  XcursorImageDestroy(out);
  return cursor;
}
