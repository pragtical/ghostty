#include <stddef.h>
#include <stdio.h>
#include <ghostty/vt.h>
#define SIZE(t) printf("%s %zu\n", #t, sizeof(t))
#define OFFSET(t, f) printf("%s.%s %zu\n", #t, #f, offsetof(t, f))

int main(void) {
  SIZE(GhosttyStyle);
  SIZE(GhosttyColorRgb);
  SIZE(GhosttyRenderStateColors);
  SIZE(GhosttyGridRef);
  SIZE(GhosttySelection);
  SIZE(GhosttyPoint);
  SIZE(GhosttyTerminalScrollbar);
  SIZE(GhosttyTerminalScrollViewport);
  SIZE(GhosttyFormatterTerminalOptions);
  SIZE(GhosttyFormatterTerminalExtra);
  SIZE(GhosttyMouseEncoderSize);
  SIZE(GhosttyMousePosition);
  SIZE(GhosttySizeReportSize);
  SIZE(GhosttyDeviceAttributes);
  SIZE(GhosttyString);
  OFFSET(GhosttyStyle, bold);
  OFFSET(GhosttyStyle, underline);
  OFFSET(GhosttyStyle, fg_color);
  OFFSET(GhosttyRenderStateColors, palette);
  OFFSET(GhosttySelection, end);
  OFFSET(GhosttyFormatterTerminalOptions, selection);
  OFFSET(GhosttyPoint, value);
  return 0;
}
