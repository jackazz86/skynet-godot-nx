/* gyro.h -- Switch motion sensors as the engine's Input.get_gyroscope().
 * MIT license; see LICENSE. */

#ifndef __GYRO_H__
#define __GYRO_H__

// Open and start the sensor handles for every controller style. Safe to call
// more than once.
void gyro_init(void);

// Average the motion since the last call, in view-rotation rates (rad/s, config
// gains and signs applied): *pitch_up is positive looking up, *turn_left is
// positive turning left. Both are 0 when gyro is off, no sensor delivered a
// fresh sample, or the motion is below the dead zone.
void gyro_sample(float *pitch_up, float *turn_left);

#endif
