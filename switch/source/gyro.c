/* gyro.c -- Switch motion sensors as the engine's Input.get_gyroscope().
 *
 * The sensor polling follows what was settled on hardware in the iortcw and
 * Serious Sam ports:
 *  - read the whole sample FIFO and average only the samples not seen yet;
 *    one sample per frame loses the motion between frames;
 *  - the handheld, Pro Controller and detached Joy-Con sensors are different
 *    handles, picked every frame. The player-pad and handheld style masks are
 *    tested SEPARATELY and an explicitly paired controller wins, otherwise a
 *    Pro Controller on an undocked console silently reads the console's own
 *    sensor;
 *  - axes, measured rather than named: X = nodding (look up/down), Y = wrists
 *    in/out with the screen square to the face (turn), Z = the steering-wheel
 *    motion (turn, summed with Y).
 * angular_velocity is in rotations per second; the engine wants rad/s.
 * MIT license; see LICENSE. */

#include <math.h>
#include <stdio.h>
#include <switch.h>

#include "config.h"
#include "gyro.h"
#include "util.h"

#define FIFO 17
#define TWO_PI 6.28318530718f

static HidSixAxisSensorHandle s_h[4]; // 0/1 joy-con pair (left/right), 2 pro, 3 handheld
static int s_ready;
static u64 s_last[4];
static int s_cur = -1;

void gyro_init(void) {
  if (s_ready) return;
  hidGetSixAxisSensorHandles(&s_h[0], 2, HidNpadIdType_No1, HidNpadStyleTag_NpadJoyDual);
  hidGetSixAxisSensorHandles(&s_h[2], 1, HidNpadIdType_No1, HidNpadStyleTag_NpadFullKey);
  hidGetSixAxisSensorHandles(&s_h[3], 1, HidNpadIdType_Handheld, HidNpadStyleTag_NpadHandheld);
  for (int i = 0; i < 4; i++) hidStartSixAxisSensor(s_h[i]);

  int want = config.gyro_drift;
  if (want < 0) want = 0;
  if (want > 2) want = 2;
  for (int i = 0; i < 4; i++) {
    Result rc = hidSetGyroscopeZeroDriftMode(s_h[i], (HidGyroscopeZeroDriftMode)want);
    if (R_FAILED(rc)) debugPrintf("[gyro] zero-drift set failed on handle %d (rc=0x%x)\n", i, (unsigned)rc);
  }
  HidGyroscopeZeroDriftMode got = HidGyroscopeZeroDriftMode_Standard;
  if (R_SUCCEEDED(hidGetGyroscopeZeroDriftMode(s_h[3], &got)))
    debugPrintf("[gyro] zero-drift mode %d, requested %d\n", (int)got, want);
  s_ready = 1;
  debugPrintf("[gyro] motion sensors started (gyro=%d yaw=%d pitch=%d roll=%d%%)\n",
              config.gyro, config.gyro_yaw, config.gyro_pitch, config.gyro_roll);
}

// Newest first. Returns how many fresh states were averaged into avg[3].
static int read_fresh(int idx, float avg[3]) {
  HidSixAxisSensorState st[FIFO];
  size_t n = hidGetSixAxisSensorStates(s_h[idx], st, FIFO);
  double sum[3] = { 0, 0, 0 };
  int fresh = 0;
  u64 newest = s_last[idx];
  for (size_t i = 0; i < n; i++) {
    if (st[i].sampling_number <= s_last[idx]) continue;
    sum[0] += st[i].angular_velocity.x;
    sum[1] += st[i].angular_velocity.y;
    sum[2] += st[i].angular_velocity.z;
    fresh++;
    if (st[i].sampling_number > newest) newest = st[i].sampling_number;
  }
  if (n > 0 && s_last[idx] == 0) {
    // first read of this source: do not integrate its whole backlog
    for (size_t i = 0; i < n; i++)
      if (st[i].sampling_number > newest) newest = st[i].sampling_number;
    s_last[idx] = newest;
    return 0;
  }
  s_last[idx] = newest;
  if (!fresh) return 0;
  avg[0] = (float)(sum[0] / fresh);
  avg[1] = (float)(sum[1] / fresh);
  avg[2] = (float)(sum[2] / fresh);
  return fresh;
}

static float dead(float v, float dz) {
  return fabsf(v) < dz ? 0.0f : v;
}

void gyro_sample(float *pitch_up, float *turn_left) {
  *pitch_up = 0.0f;
  *turn_left = 0.0f;
  if (!config.gyro) return;
  if (!s_ready) gyro_init();

  const u64 stylesPad = hidGetNpadStyleSet(HidNpadIdType_No1);
  const u64 stylesHandheld = hidGetNpadStyleSet(HidNpadIdType_Handheld);
  int idx = -1;
  const char *which = "none";
  if (stylesPad & HidNpadStyleTag_NpadFullKey) { idx = 2; which = "pro controller"; }
  else if (stylesHandheld & HidNpadStyleTag_NpadHandheld) { idx = 3; which = "handheld"; }
  else if (stylesPad & HidNpadStyleTag_NpadJoyDual) { idx = 1; which = "joy-con pair (right)"; }
  if (idx < 0) return;

  float a[3];
  int fresh = read_fresh(idx, a);
  if (!fresh && idx == 1) {
    idx = 0;
    which = "joy-con pair (left)";
    fresh = read_fresh(idx, a);
  }
  if (idx != s_cur) {
    debugPrintf("[gyro] style mask 0x%08x/0x%08x, using %s\n",
                (unsigned)stylesPad, (unsigned)stylesHandheld, which);
    s_cur = idx;
  }
  if (!fresh) return;

  const float dz = config.gyro_deadzone / 1000.0f;
  const float ax = dead(a[0], dz), ay = dead(a[1], dz), az = dead(a[2], dz);

  if (config.gyro_debug) {
    static u64 last_print;
    const u64 now = armTicksToNs(armGetSystemTick()) / 1000000ull;
    if (now - last_print > 150) {
      last_print = now;
      debugPrintf("[gyro] raw rev/s: X=%+6.3f Y=%+6.3f Z=%+6.3f (%d samples)\n", a[0], a[1], a[2], fresh);
    }
  }

  *pitch_up = ax * TWO_PI * (config.gyro_pitch / 100.0f);
  *turn_left = (ay * (config.gyro_yaw / 100.0f) + az * (config.gyro_roll / 100.0f)) * TWO_PI;
}
