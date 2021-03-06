#include "fluidkernel.cuh"
#include "fluidutil.cuh"
#include "fluidparams.cuh"
#include "helper_math.h"

__device__ float poly6Kernel(const float r)
{
    return (r >= params.m_h) ? 0.0f : params.m_poly6Coeff * powf((params.m_h2 - r * r), 3.0f);
}

__device__ float gradPoly6Kernel(const float r)
{
    return (r >= params.m_h) ? 0.0f : params.m_gradPoly6Coeff * r * powf((params.m_h2 - r * r), 2.0f);
}

__device__ float lapPoly6Kernel(const float r)
{
    return (r >= params.m_h) ? 0.0f : params.m_lapPoly6Coeff * (params.m_h2 - r * r) * (3 * params.m_h2 - 7 * r * r);
}

__device__ float spikyKernel(const float r)
{
    return (r >= params.m_h) ? 0.0f : params.m_spikyCoeff * (params.m_h - r) * (params.m_h - r) * (params.m_h - r);
}

__device__ float gradSpikyKernel(const float r)
{
    return (r >= params.m_h) ? 0.0f : params.m_gradSpikyCoeff * (params.m_h - r) * (params.m_h - r);
}

__device__ float lapViscosityKernel(const float r)
{
    return (r >= params.m_h) ? 0.0f : params.m_lapViscosityCoeff * (params.m_h - r);
}

__device__ float cohesionKernel(const float r)
{
    return (r >= params.m_h) ? 0.0f : params.m_cohesionCoeff * (r > params.m_halfh) ? powf(params.m_h - r, 3) * r * r * r : 2.0f * powf(params.m_h - r, 3) * r * r * r - params.m_h6 * 0.0156f;
}

/**
 * This term evaluates the exact boundary density given the distance from the boundary.
 * It effectively integrates the poly6 kernel * an expression for the volume of the spherical cap multiplied by a term for mass
 * in terms of the boundary density and the overall volume. See the octave directory for experiments.
 */
__device__ float boundaryDensity(const float d)
{
    // Sanity check - the spherical cap only makes sense if it's smaller than the smoothing length
    if ((d > params.m_h) || (d < 0.0f))
        return 0.0f;

    // The formula for this using buildFunctions3 is below:
    //               3 ⎛    6        4  2        2  4        6⎞          8        9
    //              c ⋅⎝35⋅c  - 180⋅c ⋅h  + 378⋅c ⋅h  - 420⋅h ⎠ + 315⋅c⋅h  + 128⋅h
    //              ───────────────────────────────────────────────────────────────
    //                                                9
    //                                           256⋅h
    // c is the signed distance from the particle to the boundary (which means it is negative)
    // It is only reliably in the range [-h,0] which maps to the range [0,0.5], although results from [0,h] will also
    // work even through it would imply that the particle is inside of the boundary.
    float c = -d;
    float c2 = c * c;
    float c3 = c2 * c;
    float c4 = c3 * c;
    float c6 = c3 * c3;
    return 1.0 - 0.0039062f * params.m_invh9 * (c3 * (35.0f * c6 - 180.0f * c4 * params.m_h2 + 378.0f * c2 * params.m_h4 - 420.0f * params.m_h6) + 315.0f * c * params.m_h8 + 128.0f * params.m_h9);
    // Note that while I have evaluated this, for some reason the function is return 1-d rather than d.
}

/**
* Determine the pressure gradient term for the boundary based on the distance to the boundary.
*/
__device__ float boundaryPressureGrad(const float d)
{
    // Quick sanity check
    if ((d > params.m_h) || (d < 0.0f))
        return 0.0f;

    // This function was derived in Octave to be:
    //  ⎛ 3 ⎛   2                2⎞        4      5⎞
    //3⋅⎝c ⋅⎝3⋅c  - 10⋅c⋅h + 10⋅h ⎠ - 5⋅c⋅h  - 2⋅h ⎠
    //──────────────────────────────────────────────
    //                        6
    //                     2⋅h
    float c = -d;
    float c2 = c * c;
    float c3 = c2 * c;
    return 1.5f * (c3 * (3.0f * c2 - 10.0f * c * params.m_h + 10.0f * params.m_h2) - 5.0f * c * params.m_h4 - 2.0f * params.m_h5) * params.m_invh6;
}

/** 
 * constructs a spinor from two (unnormalised) vectors
 */
__device__ float4 constructSpinor(const float3 &a, const float3 &b) {
    float amag = norm(a);
    float bmag = norm(b);
    float invbmag = 1.0/bmag;
    float3 an = a / amag;
    float3 bn = b * invbmag;
    
    // alpha is the amount of scaling when transforming from a to b. Note that it's the square root as the 
    // spinor is pre- and post- multiplied.
    float alpha = sqrt(amag * invbmag);
    
    // Find the half vector between a and b for the rotor
    float3 c = an+bn;
    float3 cn = c / norm(c);
     
    return alpha * make_float4(dot(an, cn),
                               an.x*cn.y - an.y*cn.x,
                               an.x*cn.z - an.z*cn.x,
                               an.y*cn.z - an.z*cn.y);
}

/** 
 * Performs the rotation of a vector by the spinor S
 */
__device__ float3 rotateSpinor(const float4 &S, const float3& a) {
    float S__0 = S.x;
    float S__12 = S.y;
    float S__13 = S.z;
    float S__23 = S.w;
    float a__1 = a.x;
    float a__2 = a.y;
    float a__3 = a.z;

    float3 b = make_float3(S__0*S__0*a__1 + 2.0f*S__0*S__12*a__2 + 2.0f*S__0*S__13*a__3 - a__1*S__12*S__12 + 2.0f*S__12*S__23*a__3 - a__1*S__13*S__13 - 2*S__13*S__23*a__2 + a__1*S__23*S__23,
                       S__0*S__0*a__2 - 2.0f*S__0*S__12*a__1 + 2.0f*S__0*S__23*a__3 - a__2*S__12*S__12 - 2.0f*S__12*S__13*a__3 + a__2*S__13*S__13 - 2.0f*S__13*S__23*a__1 - a__2*S__23*S__23,
                       S__0*S__0*a__3 - 2.0f*S__0*S__13*a__1 - 2.0f*S__0*S__23*a__2 + a__3*S__12*S__12 - 2.0f*S__12*S__13*a__2 + 2.0f*S__12*S__23*a__1 - a__3*S__13*S__13 - a__3*S__23*S__23);
    return b;
}
