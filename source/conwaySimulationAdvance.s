@
@ conwaySimulationAdvance
@
@ The routine that will actually do everything and is in IWRAM.
@ It accepts two parameters: r0 and r1, r0 being the source and r1 being the destination
@ Both of them should point to a 4bpp buffer in VRAM that is in tile column-major order (i.e.
@ the rows are arranged in an 8x8 pattern). This buffer can be drawn using background
@ modes 0, 1 or 2, by arranging the tile indices also in column-major order.
@ Both pointers should leave the space of one tile behind, and assume that the buffer has
@ 176 rows of height, even though it will only modify the 160 middle tiles (8 tiles down).
@ So that means that r0 and r1 should point to the _first_ visible row.
@
@ How the Conway Game of Life works: the screen is a grid of cells, which can be "alive"
@ or "dead". In each step of the simulation, the cell's state is considered using its
@ neighbours: if the cell is alive, it remains alive if it has 2 or 3 alive neighbors;
@ if the cell is dead, it becomes alive only if it has 3 alive neighbors.
@ This algorithm exploits the 4bpp tile layout to work on 8 cells at the same time,
@ thus using heavy parallelism to be efficient; it also reduces the memory reads to
@ a minimum, and reuses results as much as possible.
@
@ Timing: this function takes 129464 cycles total, thus half of the screen
@
#define SCREEN_HEIGHT 160
#define BUFFER_STRIDE ((SCREEN_HEIGHT+16)*4)

    .section .iwram, "ax", %progbits
    .align 2
    .arm
    .global conwaySimulationAdvance
    .type conwaySimulationAdvance STT_FUNC
conwaySimulationAdvance:
    @ Reserve some space for work here
    push    {r4-r11}

    sub     r0, r0, #4                  @ Make r0 point to the column *behind*, to use the efficient ldm instructions
    mov     r2, #160                    @ Iterate through all the 160 rows to advance the simulation
    ldr     r11, =29*BUFFER_STRIDE-4    @ Used to save some cycles on the rows
    ldr     r12, =0x11111111            @ Mask used to isolate single bits in the 4bpp buffer
.mainRowLoop:
    @ Set up the first iteration, loading the two first columns in memory
    ldmia   r0, {r3-r5}             @ first column: r4 is the column in the center
    add     r3, r3, r4
    add     r3, r3, r5              @ r3 = sum of the "middle" column's 3 cell clusters
    add     r0, r0, #BUFFER_STRIDE  @ r0 now points to the next column
    ldmia   r0, {r5-r7}             @ reuses r5
    add     r5, r5, r6
    add     r5, r5, r7              @ r5 = sum of the "right" column's 3 cell clusters

    @ Here, we should be careful not to thrash the "pure" sum pointers, since we'll need them on the next iterations
    @ Cross-add the columns together to make the neighbour-sum
    add     r7, r3, r3, lsl #4      @ shift the left neighbors
    add     r7, r7, r3, lsr #4      @ shift the right neighbors
    add     r7, r7, r5, lsl #28     @ and the right neighbors as well
    sub     r7, r7, r4              @ subtract the actual center column

    @ Now we need to parallel-check for the Conway condition: alive ? (=2 or =3) : =3
    @ Since each cell's neighbor count fits in a 4-bit number (remember, we're a 4bpp tile buffer here),
    @ the 2 last bits must be 0; besides, bit1 is always 1, and bit0 must always be 1 (3 neighbors)
    @ unless the actual cell state bit is 1 (allowing for 2 or 3 neighbors).
    @ Turns out we don't need to test for bit3 at all, because the only possible result where bit3 is
    @ set is 8 (max 8 neighbors), and in that case bit1 will be 0, turning our condition false.
    @ The condition to be tested then is:
    @ new_alive = !n.2 & n.1 & (n.0|a)
    @ We're going to implement this in parallel now:
    eor     r8, r7, r12, lsl #2     @ invert bit2 for the condition
    orr     r7, r7, r4              @ bit0 now is or'd with the alive state
    and     r7, r7, r7, lsr #1      @ bit0 now has (bit0|a)&bit1
    and     r7, r7, r8, lsr #2      @ bit0 now has the full condition up there
    and     r7, r7, r12             @ mask only the actual bits, so now r7 contains the new alive condition

    @ Store it in r1, making sure to advance the "stride", of the buffer
    str     r7, [r1], #BUFFER_STRIDE
    add     r0, r0, #BUFFER_STRIDE

    @ Now, run the next sub-iteration 14 times (yes, there's an off counter here)
    mov     r10, #14
.subLoop:
    @ At this point, let's recap:
    @ - r3 is the sum of the "left" column (since we advanced one column to the right)
    @ - r5 is the sum of the "middle" column
    @ - r6 is preserved as the current cell state (so we can subtract and use later)
    @ - r0 should point to the "right" column's data, ready to be used
    @ this first half takes 25 cycles to process 8 cells, it should be kept under 32 cycles properly

    @ Do the first half of the cross-add right now, to free r3
    add     r8, r5, r5, lsl #4      @ shift the left neighbors
    add     r8, r8, r3, lsr #28     @ shift the neighbors from the left column

    @ Load the "right column" and add it
    ldmia   r0, {r3, r4, r7}        @ r4 will be the "right" cell state
    add     r3, r3, r4
    add     r3, r3, r7              @ now r3 is the sum of the "right" column (yeah, before r5, but eh)

    @ Cross add the columns together and subtract the current state
    add     r8, r8, r5, lsr #4      @ shift the right neighbors
    add     r8, r8, r3, lsl #28     @ shift the neighbors from the right column
    sub     r8, r8, r6              @ subtract the current state

    @ To the Conway condition as explained up there
    eor     r9, r8, r12, lsl #2     @ 9.bit2 = !n2
    orr     r8, r8, r6              @ 8.bit0 = n0|a
    and     r8, r8, r8, lsr #1      @ 8.bit0 = n1&(n0|a)
    and     r8, r8, r9, lsr #2      @ 8.bit0 = !n2&n1&(n0|a)
    and     r8, r8, r12             @ mask the actual bits

    @ Now, same scheme, write it to r1 and advance it
    str     r8, [r1], #BUFFER_STRIDE
    add     r0, r0, #BUFFER_STRIDE

    @ The second half of the loop is identical to the first, except with the registers swapped
    @ - r5 is now the sum of the "left" column
    @ - r3 is the sum of the "middle" column
    @ - r4 is the current cell state
    @ since the loop is basically a copy of the first loop, it should take the same time

    @ Do the first half of the cross-add right now, to free r5
    add     r8, r3, r3, lsl #4      @ shift the left neighbors
    add     r8, r8, r5, lsr #28     @ shift the neighbors from the left column

    @ Load the "right column" and add it
    ldmia   r0, {r5, r6, r7}        @ r6 will be the "right" cell state
    add     r5, r5, r6
    add     r5, r5, r7              @ now r5 is the sum of the "right" column (yeah, before r5, but eh)

    @ Cross add the columns together and subtract the current state
    add     r8, r8, r3, lsr #4      @ shift the right neighbors
    add     r8, r8, r5, lsl #28     @ shift the neighbors from the right column
    sub     r8, r8, r4              @ subtract the current state

    @ To the Conway condition as explained up there
    eor     r9, r8, r12, lsl #2     @ 9.bit3 = !n2
    orr     r8, r8, r4              @ 8.bit0 = n0|a
    and     r8, r8, r8, lsr #1      @ 8.bit0 = n1&(n0|a)
    and     r8, r8, r9, lsr #2      @ 8.bit0 = !n2&n1&(n0|a)
    and     r8, r8, r12             @ mask the actual bits

    @ Write it to r1 and advance it
    str     r8, [r1], #BUFFER_STRIDE
    add     r0, r0, #BUFFER_STRIDE

    @ Both loops (with the loop counter) should take 56 cycles here. Yeah, we could unroll even more, since
    @ the inner loop is being run 160 cycles, but at some point we will run out of IWRAM
    subs    r10, r10, #1            @ subtract 1 from the secondary loop counter
    bne     .subLoop                @ branch if there are still loops

    @ With that, we're back to the initial state for the loop:
    @ - r3 is now the sum of the "left" column
    @ - r5 is the sum of the "middle" column
    @ - r6 is the current cell state
    @ Process the final column - we don't need to load the next neighbours, since they're zero
    
    @ Cross add the neighbors
    add     r7, r5, r5, lsl #4      @ shift the left neighbors
    add     r7, r7, r3, lsr #28     @ shift the neighbors form the left column
    add     r7, r7, r5, lsr #4      @ shift the right neighbors
    sub     r7, r7, r6              @ subtract the actual state

    @ Implement Conway's condition one last time
    eor     r8, r7, r12, lsl #2     @ invert bit2 for the condition
    orr     r7, r7, r6              @ bit0 now is or'd with the alive state
    and     r7, r7, r7, lsr #1      @ bit0 now has (bit0|a)&bit1
    and     r7, r7, r8, lsr #2      @ bit0 now has the full condition up there
    and     r7, r7, r12             @ mask only the actual bits, so now r7 contains the new alive condition

    @ Store in r1, but rollback the buffer stride
    str     r7, [r1], -r11          @ roll back by 29 rows here
    sub     r0, r0, r11

    @ Update r0 and do the next row
    sub     r0, r0, #BUFFER_STRIDE
    subs    r2, r2, #1              @ subtract 1
    bne     .mainRowLoop           @ and go back if it's still not 0

    pop     {r4-r11}
    bx      lr
