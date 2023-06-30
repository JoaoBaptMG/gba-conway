#include <tonc.h>

IWRAM_CODE u32 xorshf96(void) 
{    
    /* A George Marsaglia generator, period 2^96-1 */
	static u32 x=123456789, y=362436069, z=521288629;
	u32 t;

	x ^= x << 16;
	x ^= x >> 5;
	x ^= x << 1;

	t = x;
	x = y;
	y = z;

	z = t ^ x ^ y;
	return z;
}
