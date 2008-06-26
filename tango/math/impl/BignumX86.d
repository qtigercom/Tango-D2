/** Optimised asm arbitrary precision arithmetic ('bignum') 
 * routines for X86 processors.
 *
 * All functions operate on arrays of uints, stored LSB first.
 * If there is a destination array, it will be the first parameter.
 * Currently, all of these functions are subject to change, and are
 * intended for internal use only.
 *
 * Author: Don Clugston
 * Date: May 2008.
 *
 * License: Public Domain
 *
 * In simple terms, there are 3 modern x86 microarchitectures:
 * (a) the P6 family (Pentium Pro, PII, PIII, PM, Core), produced by Intel;
 * (b) the K6, Athlon, and AMD64 families, produced by AMD; and
 * (c) the Pentium 4, produced by Marketing.
 *
 * This code has been optimised for the Intel P6 family, except that it only
 * uses the basic instruction set (doesn't use MMX, SSE, SSE2)
 * Generally the code remains near-optimal for Core2, after translating
 * EAX-> RAX, etc, since all these CPUs use essentially the same pipeline.
 * The code uses techniques described in Agner Fog's superb manuals available
 * at www.agner.org.
 * Not optimal for AMD64, which can do two memory loads per cycle (Intel
 * CPUs can only do one).
 *
 *  Timing results (cycles per int)
 *         PentiumM Core2
 *  +,-      2.25   2.25
 *  &,|,^    2.0    2.0
 *  <<,>>    2.0    2.0
 *  cmp      2.0    2.0
 *  *        5.0
 *  mulAdd   5.4
 *  div     18.0
 */

module tango.math.impl.BignumX86;

/*  
  Naked asm is used throughout, because:
  (a) it frees up the EBP register
  (b) compiler bugs prevent the use of .ptr when a frame pointer is used.
*/

private:
version(D_InlineAsm_X86) {
/* Duplicate string s, with n times, substituting index for '@'.
 *
 * Each instance of '@' in s is replaced by 0,1,...n-1. This is a helper
 * function for some of the asm routines.
 */
char [] indexedLoopUnroll(int n, char [] s)
{
    char [] u;
    for (int i = 0; i<n; ++i) {
        char [] nstr= (i>9 ? ""~ cast(char)('0'+i/10) : "") ~ cast(char)('0' + i%10);
        
        int last = 0;
        for (int j = 0; j<s.length; ++j) {
            if (s[j]=='@') {
                u ~= s[last..j] ~ nstr;
                last = j+1;
            }
        }
        if (last<s.length) u = u ~ s[last..$];
        
    }
    return u;    
}
unittest
{
assert(indexedLoopUnroll(3, "@*23;")=="0*23;1*23;2*23;");
}

package:
/** Multi-byte addition or subtraction
 *    dest[] = src1[] + src2[] + carry (0 or 1).
 * or dest[] = src1[] - src2[] - carry (0 or 1).
 * Returns carry or borrow (0 or 1).
 * Set op == '+' for addition, '-' for subtraction.
 */
uint multibyteAddSub(char op)(uint[] dest, uint [] src1, uint [] src2, uint carry)
{
    // Timing:
    // Pentium M: 2.25/int
    // P6 family, Core2 have a partial flags stall when reading the carry flag in
    // an ADC, SBB operation after an operation such as INC or DEC which
    // modifies some, but not all, flags. We avoid this by storing carry into
    // a resister (AL), and restoring it after the branch.
    // * Count UP to zero (from -len) to minimize loop overhead.

    enum { UNROLLFACTOR = 8 };
    enum { LASTPARAM = 4*4 } // 3* pushes + return address.
    asm {
        naked;
        push EDI;
        push EBX;
        push ESI;
        align 16; // This aligns L1 on a 16-byte boundary.
        mov ECX, [ESP + LASTPARAM + 4*4]; // dest.length;
        mov EDX, [ESP + LASTPARAM + 3*4]; // src1.ptr
        mov EDI, [ESP + LASTPARAM + 5*4]; // dest.ptr
             // Carry is automatically in EAX
        mov ESI, [ESP + LASTPARAM + 1*4]; // src2.ptr
        lea EDX, [EDX + 4*ECX]; // EDX = end of src1.
        lea EDI, [EDI + 4*ECX]; // EDI = end of dest.
        lea ESI, [ESI + 4*ECX]; // EBP = end of src2.        
        neg ECX;
        and ECX, 0xFFFF_FFF8;
        jz L2; // length <8
    L1:
        shr AL, 1; // get carry from the lsb of AL
    }
    mixin(" asm {"
    ~ indexedLoopUnroll( UNROLLFACTOR, "
        mov EAX, [@*4+EDX+ECX*4];
        "~ (op=='+'?"adc" : "sbb") ~ " EAX, [@*4+ESI+ECX*4];
        mov [@*4+EDI+ECX*4], EAX;
        ") ~ "}");
    asm {
        setc AL; // Save carry into the lsb of AL
        add ECX, UNROLLFACTOR;        
        jnz L1;
L2:
        mov ECX, [ESP + LASTPARAM + 2*4]; // dest.length;
        and ECX, 7;
        jz done; // divisible by 8 -- no residue
        neg ECX;
L3: // Do the residual 1..7 ints.
        shr AL, 1; // get carry from EAX
        mov EAX, [EDX+ECX*4];
    }
    static if (op=='+')
    {
        asm { adc EAX, [ESI+ECX*4]; }
    }
    else 
    {
        asm { sbb EAX, [ESI+ECX*4]; }
    }
    asm {
        mov [EDI+ECX*4], EAX;       
        setc AL; // save carry
        add ECX, 1;
        jnz L3;                
done:
        and EAX, 1; // make it O or 1.
        pop ESI;
        pop EBX;
        pop EDI;
        ret 6*4;
    } 
}

unittest
{
    uint [] a = new uint[20];
    uint [] b = new uint[20];
    uint [] c = new uint[20];
    for (int i=0; i<a.length; ++i)
    {
        if (i&1) a[i]=0x8000_0000 + i;
        else a[i]=i;
        b[i]= 0x8000_0003;
    }
    c[19]=0x3333_3333;
    uint carry = multibyteAddSub!('+')(c[0..18], a[0..18], b[0..18], 0);
    assert(carry==1);
    assert(c[0]==0x8000_0003);
    assert(c[1]==4);
    assert(c[19]==0x3333_3333); // check for overrun
}

/** dest[] += carry, or dest[] -= carry.
 *  op must be '+' or '-'
 *  Returns final carry or borrow (0 or 1)
 */
uint multibyteAddSubCarry(char op)(uint[] dest, uint carry)
{
    enum { LASTPARAM = 1*4 } // 0* pushes + return address.
    asm {
        naked;
        mov ECX, [ESP + LASTPARAM + 0*4]; // dest.length;
        mov EDX, [ESP + LASTPARAM + 1*4]; // dest.ptr
        // EAX  = carry
L1: ;
    }
    static if (op=='+')
        asm { add [EDX], EAX; }
    else 
        asm { sub [EDX], EAX; }    
    asm {
        mov EAX, 1;
        jnc L2;
        add EDX, 4;        
        dec ECX;
        jnz L1;
        mov EAX, 2;
L2:     dec EAX;
        ret 2*4;
    }
}

/** Dest[] = src1[] op src2[]
*   where op == '&' or '|' or '^'
*/
uint multibyteLogical(char op)(uint [] dest, uint [] src1, uint [] src2)
{
    // PM: 2 cycles/operation. Limited by execution unit p2.
    // (AMD64 could reach 1.5 cycles/operation since it has TWO read ports.
    // On Core2, we could use SSE2 with 128-bit reads).
    enum { LASTPARAM = 3*4 } // 2* pushes + return address.
    asm {
        naked;
        push EDI;
        push ESI;        
        mov EDI, [ESP + LASTPARAM + 4*5]; // dest.ptr
        mov ECX, [ESP + LASTPARAM + 4*4]; // dest.length;
        mov EDX, [ESP + LASTPARAM + 4*3]; // src1.ptr;
        mov ESI, [ESP + LASTPARAM + 4*1]; // src2.ptr
        lea EDI, [EDI + 4*ECX]; // EDI = end of dest.
        lea EDX, [EDX + 4*ECX]; // EDX = end of src1.
        lea ESI, [ESI + 4*ECX]; // ESI = end of src2.
        neg ECX;
L1:
        mov EAX, [EDX+ECX*4];
    }
    static if (op=='&') asm {        and EAX, [ESI+ECX*4]; }
    else   if (op=='|') asm {        or  EAX, [ESI+ECX*4]; }
    else   if (op=='^') asm {        xor EAX, [ESI+ECX*4]; }
    asm {
        mov [EDI + ECX *4], EAX;
        add ECX, 1;
        jl L1;
        
        pop ESI;
        pop EDI;
        ret 6*4;
    } 
}

unittest
{
    uint [] bb = [0x0F0F_0F0F, 0xF0F0_F0F0, 0x0F0F_0F0F, 0xF0F0_F0F0];
    for (int qqq=0; qqq<3; ++qqq) {
        uint [] aa = [0xF0FF_FFFF, 0x1222_2223, 0x4555_5556, 0x8999_999A, 0xBCCC_CCCD, 0xEEEE_EEEE];    
        
        switch(qqq) {
        case 0:
            multibyteLogical!('&')(aa[1..3], aa[1..3], bb[0..4]);
            assert(aa[1]==0x0202_0203 && aa[2]==0x4050_5050 && aa[3]== 0x8999_999A);
            break;
        case 1:
            multibyteLogical!('|')(aa[1..2], aa[1..2], bb[0..3]);
            assert(aa[1]==0x1F2F_2F2F && aa[2]==0x4555_5556 && aa[3]== 0x8999_999A);
            break;
        case 2:
            multibyteLogical!('^')(aa[1..2], aa[1..2], bb[0..3]);
            assert(aa[1]==0x1D2D_2D2C && aa[2]==0x4555_5556 && aa[3]== 0x8999_999A);
            break;
        }
        
        assert(aa[0]==0xF0FF_FFFF);
    }
}
    
/** dest[] = src[] << numbits
 *  numbits must be in the range 1..31
 */
void multibyteShl(uint [] dest, uint [] src, uint numbits)
{
    // Timing: Optimal for P6 family.
    // 2.0 cycles/int on PPro..PM (limited by execution port p0)
    // Terrible performance on AMD64, which has 7 cycles for SHLD!!
    enum { LASTPARAM = 4*4 } // 3* pushes + return address.
    asm {
        naked;
        push ESI;
        push EDI;
        push EBX;
        mov EDI, [ESP + LASTPARAM + 4*3]; //dest.ptr;
        mov EBX, [ESP + LASTPARAM + 4*2]; //dest.length;
        mov ESI, [ESP + LASTPARAM + 4*1]; //src.ptr;
        mov ECX, EAX; // numbits;

        mov EAX, [-4+ESI + 4*EBX];
        cmp EBX, 1;
        jz L_last;
        mov EDX, [-4+ESI + 4*EBX];
        test EBX, 1;
        jz L_odd;
        sub EBX, 1;        
L_even:
        mov EDX, [-4+ ESI + 4*EBX];
        shld EAX, EDX, CL;
        mov [EDI+4*EBX], EAX;
L_odd:
        mov EAX, [-8+ESI + 4*EBX];
        shld EDX, EAX, CL;
        mov [-4+EDI + 4*EBX], EDX;        
        sub EBX, 2;
        jg L_even;
L_last:
        shl EAX, CL;
        mov [EDI], EAX;

        pop EBX;
        pop EDI;
        pop ESI;
        ret 4*4;
     }
}

/** dest[] = src[] >> numbits
 *  numbits must be in the range 1..31
 */
void multibyteShr(uint [] dest, uint [] src, uint numbits)
{
    // Timing: Optimal for P6 family.
    // 2.0 cycles/int on PPro..PM (limited by execution port p0)
    // Terrible performance on AMD64, which has 7 cycles for SHRD!!
    enum { LASTPARAM = 4*4 } // 3* pushes + return address.
    asm {
        naked;
        push ESI;
        push EDI;
        push EBX;
        mov EDI, [ESP + LASTPARAM + 4*3]; //dest.ptr;
        mov EBX, [ESP + LASTPARAM + 4*2]; //dest.length;
        mov ESI, [ESP + LASTPARAM + 4*1]; //src.ptr;
        mov ECX, EAX; // numbits;

        lea EDI, [EDI + 4*EBX]; // EDI = end of dest
        lea ESI, [ESI + 4*EBX]; // ESI = end of src
        neg EBX;                // count UP to zero.
        mov EAX, [ESI + 4*EBX];
        cmp EBX, -1;
        jz L_last;
        mov EDX, [ESI + 4*EBX];
        test EBX, 1;
        jz L_odd;
        add EBX, 1;        
L_even:
        mov EDX, [ ESI + 4*EBX];
        shrd EAX, EDX, CL;
        mov [-4 + EDI+4*EBX], EAX;
L_odd:
        mov EAX, [4 + ESI + 4*EBX];
        shrd EDX, EAX, CL;
        mov [EDI + 4*EBX], EDX;        
        add EBX, 2;
        jl L_even;
L_last:
        shr EAX, CL;
        mov [-4 + EDI], EAX;
        
        pop EBX;
        pop EDI;
        pop ESI;
        ret 4*4;
     }
}

unittest
{
    uint [] aa = [0x1222_2223, 0x4555_5556, 0x8999_999A, 0xBCCC_CCCD, 0xEEEE_EEEE];
    multibyteShr(aa[0..$-2], aa, 4);
	assert(aa[0]==0x6122_2222 && aa[1]==0xA455_5555 && aa[2]==0x0899_9999);
	assert(aa[3]==0xBCCC_CCCD);

    aa = [0x1222_2223, 0x4555_5556, 0x8999_999A, 0xBCCC_CCCD, 0xEEEE_EEEE];
    multibyteShr(aa[0..$-1], aa, 4);
	assert(aa[0] == 0x6122_2222 && aa[1]==0xA455_5555 
	    && aa[2]==0xD899_9999 && aa[3]==0x0BCC_CCCC);

    aa = [0xF0FF_FFFF, 0x1222_2223, 0x4555_5556, 0x8999_999A, 0xBCCC_CCCD, 0xEEEE_EEEE];
    multibyteShl(aa[1..4], aa[1..$], 4);
	assert(aa[0] == 0xF0FF_FFFF && aa[1] == 0x2222_2230 
	    && aa[2]==0x5555_5561 && aa[3]==0x9999_99A4 && aa[4]==0x0BCCC_CCCD);
}

/** dest[] = src[] * multiplier + carry.
 * Returns carry.
 */
uint multibyteMul(uint[] dest, uint[] src, uint multiplier, uint carry)
{
    // Timing: definitely not optimal.
    // Pentium M: 5.0 cycles/operation, has 3 resource stalls/iteration
    // Fastest implementation found was 4.6 cycles/op, but not worth the complexity.

    enum { LASTPARAM = 4*4 } // 4* pushes + return address.
    // We'll use p2 (load unit) instead of the overworked p0 or p1 (ALU units)
    // when initializing variables to zero.
    version(D_PIC)
    {
        enum { zero = 0 }
    }
    else
    {
        static int zero = 0;
    }
    asm {
        naked;      
        push ESI;
        push EDI;
        push EBX;
        
        mov EDI, [ESP + LASTPARAM + 4*4]; // dest.ptr
        mov EBX, [ESP + LASTPARAM + 4*3]; // dest.length
        mov ESI, [ESP + LASTPARAM + 4*2];  // src.ptr
        align 16;
        lea EDI, [EDI + 4*EBX]; // EDI = end of dest
        lea ESI, [ESI + 4*EBX]; // ESI = end of src
        mov ECX, EAX; // [carry]; -- last param is in EAX.
        neg EBX;                // count UP to zero.
        test EBX, 1;
        jnz L_odd;
        add EBX, 1;
 L1:
        mov EAX, [-4 + ESI + 4*EBX];
        mul int ptr [ESP+LASTPARAM]; //[multiplier];
        add EAX, ECX;
        mov ECX, zero;
        mov [-4+EDI + 4*EBX], EAX;
        adc ECX, EDX;
L_odd:        
        mov EAX, [ESI + 4*EBX];  // p2
        mul int ptr [ESP+LASTPARAM]; //[multiplier]; // p0*3, 
        add EAX, ECX;
        mov ECX, zero;
        adc ECX, EDX;
        mov [EDI + 4*EBX], EAX;
        add EBX, 2;
        jl L1;
        
        mov EAX, ECX; // get final carry

        pop EBX;
        pop EDI;
        pop ESI;
        ret 5*4;
     }
}

unittest
{
    uint [] aa = [0xF0FF_FFFF, 0x1222_2223, 0x4555_5556, 0x8999_999A, 0xBCCC_CCCD, 0xEEEE_EEEE];
    multibyteMul(aa[1..4], aa[1..4], 16, 0);
	assert(aa[0] == 0xF0FF_FFFF && aa[1] == 0x2222_2230 && aa[2]==0x5555_5561 && aa[3]==0x9999_99A4 && aa[4]==0x0BCCC_CCCD);
}

/**
 * dest[] += src[] * multiplier + carry(0..FFFF_FFFF).
 * Returns carry out of MSB (0..FFFF_FFFF).
 */
uint multibyteMulAdd(uint [] dest, uint[] src, uint multiplier, uint carry)
{
    // Timing: This is the most time-critical bignum function.
    // Pentium M: 5.4 cycles/operation, still has 2 resource stalls + 1 load block/iteration
    
    // The bottlenecks in this code are extremely complicated. The MUL, ADD, and ADC
    // need 4 cycles on each of the ALUs units p0 and p1. So we use memory load 
    // (unit p2) for initializing registers to zero.
    // There are also dependencies between the instructions, and we run up against the
    // ROB-read limit (can only read 2 registers per cycle).
    // We also need the number of uops in the loop to be a multiple of 3.
    // The only available execution unit for this is p3 (memory write)
    
    // The main loop is pipelined and unrolled by 2, so entry to the loop is also complicated.
    
    version(D_PIC) {
        enum { zero = 0 }
    } else {
        // use p2 (load unit) instead of the overworked p0 or p1 (ALU units)
        // when initializing registers to zero.
        static int zero = 0;
        // use p3/p4 units 
        static int storagenop; // write-only
    }
    
    enum { LASTPARAM = 5*4 } // 4* pushes + return address.
    asm {
        naked;
        
        push ESI;
        push EDI;
        push EBX;
        push EBP;
        mov EDI, [ESP + LASTPARAM + 4*4]; // dest.ptr
        mov EBX, [ESP + LASTPARAM + 4*3]; // dest.length
        align 16;
        nop;
        mov ESI, [ESP + LASTPARAM + 4*2];  // src.ptr
        lea EDI, [EDI + 4*EBX]; // EDI = end of dest
        lea ESI, [ESI + 4*EBX]; // ESI = end of src
        mov EBP, 0;
        mov ECX, EAX; // ECX = input carry.
        neg EBX;                // count UP to zero.
        mov EAX, [ESI+4*EBX];
        test EBX, 1;
        jnz L_enter_odd;
        // Entry point for even length
        add EBX, 1;
        mov EBP, ECX; // carry
        
        mul int ptr [ESP+LASTPARAM];
        mov ECX, 0;
 
        add EBP, EAX;
        mov EAX, [ESI+4*EBX];
        adc ECX, EDX;

        mul int ptr [ESP+LASTPARAM];

        add [-4+EDI+4*EBX], EBP;
        mov EBP, zero;
    
        adc ECX, EAX;
        mov EAX, [4+ESI+4*EBX];
    
        adc EBP, EDX;    
        add EBX, 2;
        jnl L_done;
        // Main loop
L1:
        mul int ptr [ESP+LASTPARAM];
        add [-8+EDI+4*EBX], ECX;
        mov ECX, zero;
 
        adc EBP, EAX;
        mov EAX, [ESI+4*EBX];
        
        adc ECX, EDX;
    }
    version(D_PIC) {} else {
     asm {
        mov storagenop, EDX; // make #uops in loop a multiple of 3
     }
    }
    asm {        
        mul int ptr [ESP+LASTPARAM];
        add [-4+EDI+4*EBX], EBP;
        mov EBP, zero;
    
        adc ECX, EAX;
        mov EAX, [4+ESI+4*EBX];
    
        adc EBP, EDX;    
        add EBX, 2;
        jl L1;
L_done:
        add [-8+EDI+4*EBX], ECX;
        mov EAX, EBP; // get final carry
        adc EAX, 0;
        pop EBP;
        pop EBX;
        pop EDI;
        pop ESI;
        ret 5*4;
        
L_enter_odd:
        mul int ptr [ESP+LASTPARAM];
        mov EBP, zero;   
        add ECX, EAX;
        mov EAX, [4+ESI+4*EBX];
    
        adc EBP, EDX;    
        add EBX, 2;
        jl L1;
        jmp L_done;

     }
}

unittest {
    
    uint [] aa = [0xF0FF_FFFF, 0x1222_2223, 0x4555_5556, 0x8999_999A, 0xBCCC_CCCD, 0xEEEE_EEEE];
    uint [] bb = [0x1234_1234, 0xF0F0_F0F0, 0x00C0_C0C0, 0xF0F0_F0F0, 0xC0C0_C0C0];
    multibyteMulAdd(bb[1..$-1], aa[1..$], 16, 5);
	assert(bb[0] == 0x1234_1234 && bb[4] == 0xC0C0_C0C0);
    assert(bb[1] == 0x2222_2230 + 0xF0F0_F0F0+5 && bb[2] == 0x5555_5561+0x00C0_C0C0+1
	    && bb[3] == 0x9999_99A4+0xF0F0_F0F0 );
}

/**  dest[] /= divisor.
 * overflow is the initial remainder, and must be in the range 0..divisor-1.
 * divisor must not be a power of 2 (use right shift for that case;
 * A division by zero will occur if divisor is a power of 2).
 * Returns the final remainder
 *
 * Based on public domain code by Eric Bainville. 
 * (http://www.bealto.com/) Used with permission.
 */
uint multibyteDiv(uint [] dest, uint divisor, uint overflow)
{
    // Timing: limited by a horrible dependency chain.
    // Pentium M: 18 cycles/op, 8 resource stalls/op.
    // EAX, EDX = scratch, used by MUL
    // EDI = dest
    // CL = shift
    // ESI = quotient
    // EBX = remainderhi
    // EBP = remainderlo
    // [ESP-4] = mask
    // [ESP] = kinv (2^64 /divisor)
    enum { LASTPARAM = 5*4 } // 4* pushes + return address.
    enum { LOCALS = 2*4} // MASK, KINV
    asm {
        naked;
        
        push ESI;
        push EDI;
        push EBX;
        push EBP;
        
        mov EDI, [ESP + LASTPARAM + 4*2]; // dest.ptr
        mov EBX, [ESP + LASTPARAM + 4*1]; // dest.length

        // Loop from msb to lsb
        lea     EDI, [EDI + 4*EBX];        
        mov EBP, EAX; // rem is the input remainder, in 0..divisor-1
        // Build the pseudo-inverse of divisor k: 2^64/k
        // First determine the shift in ecx to get the max number of bits in kinv
        xor     ECX, ECX;
        mov     EAX, [ESP + LASTPARAM]; //divisor;
        mov     EDX, 1;
kinv1:
        inc     ECX;
        ror     EDX, 1;
        shl     EAX, 1;
        jnc     kinv1;
        dec     ECX;
        // Here, ecx is a left shift moving the msb of k to bit 32
        
        mov     EAX, 1;
        shl     EAX, CL;
        dec     EAX;
        ror     EAX, CL ; //ecx bits at msb
        push    EAX;
        
        
        // Then divide 2^(32+cx) by divisor (edx already ok)
        xor     EAX, EAX;
        div     int ptr [ESP + LASTPARAM +  LOCALS-4*1]; //divisor;
        push    EAX; // kinv        
        align   16;
L2:
        // Get 32 bits of quotient approx, multiplying
        // most significant word of (rem*2^32+input)
        mov     EAX, [ESP+4]; //MASK;
        and     EAX, [EDI - 4];
        or      EAX, EBP;
        rol     EAX, CL;
        mov     EBX, EBP;
        mov     EBP, [EDI - 4];
        mul     int ptr [ESP]; //KINV;
                
        shl     EAX, 1;
        rcl     EDX, 1;
        
        // Multiply by k and subtract to get remainder
        // Subtraction must be done on two words
        mov     EAX, EDX;
        mov     ESI, EDX; // quot = high word
        mul     int ptr [ESP + LASTPARAM+LOCALS]; //divisor;
        sub     EBP, EAX;
        sbb     EBX, EDX;   
        jz      Lb;  // high word is 0, goto adjust on single word

        // Adjust quotient and remainder on two words
Ld:     inc     ESI;
        sub     EBP, [ESP + LASTPARAM+LOCALS]; //divisor;
        sbb     EBX, 0;
        jnz     Ld;
        
        // Adjust quotient and remainder on single word
Lb:     cmp     EBP, [ESP + LASTPARAM+LOCALS]; //divisor;
        jc      Lc; // rem in 0..divisor-1, OK        
        sub     EBP, [ESP + LASTPARAM+LOCALS]; //divisor;
        inc     ESI;
        jmp     Lb;
        
        // Store result
Lc:
        mov     [EDI - 4], ESI;
        lea     EDI, [EDI - 4];
        dec     int ptr [ESP + LASTPARAM + 4*1+LOCALS]; // len
        jnz	L2;
        
        pop EAX; // discard kinv
        pop EAX; // discard mask
        
        mov     EAX, EBP; // return final remainder
        pop     EBP;
        pop     EBX;
        pop     EDI;
        pop     ESI;        
        ret     3*4;
    }
}

unittest {
    uint [] aa = new uint[101];
    for (int i=0; i<aa.length; ++i) aa[i] = 0x8765_4321 * (i+3);
    uint overflow = multibyteMul(aa, aa, 0x8EFD_FCFB, 0x33FF_7461);
    uint r = multibyteDiv(aa, 0x8EFD_FCFB, overflow);
    for (int i=0; i<aa.length-1; ++i) assert(aa[i] == 0x8765_4321 * (i+3));
    assert(r==0x33FF_7461);

}

} // version(D_InlineAsm_X86)
