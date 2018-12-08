// Directional modulation on GPU
// PRELIMINARY / PROOF OF CONCEPT

#include <stdio.h>
#include <stdlib.h>
#include <assert.h>
#include <cuda_runtime.h>
#include <cublas_v2.h>
#include <cusolverDn.h>
#include <cuComplex.h>

#define PI 3.141592653589793238462643383279502884197169399375105820974

#include <sys/time.h>

typedef struct {
    struct timeval startTime;
    struct timeval endTime;
} Timer;

void startTime(Timer* timer) {
    gettimeofday(&(timer->startTime), NULL);
}

void stopTime(Timer* timer) {
    gettimeofday(&(timer->endTime), NULL);
}

float elapsedTime(Timer timer) {
    return ((float) ((timer.endTime.tv_sec - timer.startTime.tv_sec) \
                + (timer.endTime.tv_usec - timer.startTime.tv_usec)/1.0e6));
}

void printMatrix(int m, int n, const cuComplex *A, int lda, const char *name)
{
    for(int row = 0 ; row < m ; row++){
        for(int col = 0 ; col < n ; col++){
            cuComplex Areg = A[row + col*lda];
            printf("%s(%d,%d) = %f%+fi\n", name, row+1, col+1, cuCrealf(Areg), cuCimagf(Areg));
        }
    }
}

// in MATLAB, the construction looked sort of like this
// for a problem with 2 specified directions:
//
//    1        (             0 0          ( Td[0]  Td[1] ) )
// ______ * exp( -2*j*pi*d * 1 1   .*  cos( Td[0]  Td[1] ) )
// sqrt(M)     (             ...          (     ...      ) )
//             (             M-1          ( Td[0]  Td[1] ) )
//
// note that the number of antenna elements determines the number
// of rows, while the number of specified directions determines the
// number of columns.
//
// the argument to exp is real until it is multiplied by j,
// which is what makes the overall result complex, so it seems
// splitting this up by Euler's formula might be the way to go
// to actually build the complex values in the last step using
// all real arithmetic up to that.
//
// the following is a first pass at what that looks like -
// it will need to be verified...
//
// the real part of H(Theta_d) =
//
//    1        (          0 0          ( Td[0]  Td[1] ) )
// ______ * cos( 2*pi*d * 1 1   .*  cos( Td[0]  Td[1] ) )
// sqrt(M)     (          ...          (     ...      ) )
//             (          M-1          ( Td[0]  Td[1] ) )
//
// the imaginary part of H(Theta_d) =
//
//   -j        (          0 0          ( Td[0]  Td[1] ) )
// ______ * sin( 2*pi*d * 1 1   .*  cos( Td[0]  Td[1] ) )
// sqrt(M)     (          ...          (     ...      ) )
//             (          M-1          ( Td[0]  Td[1] ) )
//

const unsigned int STEERING_BLOCK_SIZE = 16;

__global__ void steering(unsigned int M, unsigned int K, float d, const float *Td, cuComplex *H_Td) {

    // calculate the steering matrix
    // one element per thread, owner writes

    unsigned int r = blockIdx.y * blockDim.y + threadIdx.y;
    unsigned int c = blockIdx.x * blockDim.x + threadIdx.x;
    float norm = 1 / sqrtf(M);
    if ((r < M) && (c < K)) {
        float arg = 2 * PI * d * r * cosf(Td[c]);
        unsigned int cmaj = c * M + r;
        sincosf(arg, &H_Td[cmaj].y, &H_Td[cmaj].x);
        H_Td[cmaj].x *= norm;
        H_Td[cmaj].y *= -norm;
    }
}

const unsigned int CIDENT_BLOCK_SIZE = 16;

__global__ void Cident(unsigned int n, cuComplex *I) {

    // calculate a complex identity matrix
    // one element per thread, owner writes

    unsigned int r = blockIdx.y * blockDim.y + threadIdx.y;
    unsigned int c = blockIdx.x * blockDim.x + threadIdx.x;
    if ((r < n) && (c < n))
        I[c * n + r] = make_cuFloatComplex((r == c), 0.);
}

// there were pretty bad problems that seemed to be related to effective
// address calculation of structure members when the structure was on
// the device, but it was found that the cublas pointer mode needed to
// be changed...  that might have been the whole issue - there is a thought
// that the scalars had to be on the device to get async dispatches...
// not sure about that now either

// this is constant until/unless number/direction of receivers change
// if/when these changes occur, only Td_k and/or Td_deg are affected
//struct dm_parms {
//    unsigned int M;      // number of antenna elements
//    float d;    // spacing of antenna elements, in wavelengths
//    float P;    // average power, presumably Watts, typically 1 for sims
//    float B;    // beta 1; power allocation; 1 if not using null space
//    float Td_c; // pi / 180 for scaling
//    unsigned int Td_k;   // number of Td elements used, i.e., # of directions
//    float Td_deg[64]; // specified directions in degrees; Theta_d
//};

int main(int argc, char *argv[])
{
    Timer timer;

    cudaStream_t cudaStream = NULL;

    cudaError_t cudaError1 = cudaSuccess;
    cudaError_t cudaError2 = cudaSuccess;
    cudaError_t cudaError3 = cudaSuccess;
    cudaError_t cudaError4 = cudaSuccess;

    cublasHandle_t cublasHandle = NULL;
    cublasStatus_t cublasStatus = CUBLAS_STATUS_SUCCESS;

    cusolverDnHandle_t cusolverDnHandle = NULL;
    cusolverStatus_t cusolverStatus = CUSOLVER_STATUS_SUCCESS;

//    struct dm_parms *dm_h;
    unsigned int M;    // # of antenna elements
    unsigned int Td_k; // # of Td elements used, i.e., # of directions
    float Td_deg[64];  // specified directions in degrees; Theta_d
    float d;    // spacing of antenna elements, in wavelengths
    float P;    // average power, presumably Watts, typically 1 for sims
    float B;    // beta 1; power allocation; 1 if not using null space
    float Td_c; // pi / 180 for scaling
    cuComplex alpha, beta, scale;

    cuComplex *H_Td = NULL;  // for diagnostics
    cuComplex *HH   = NULL;
    cuComplex *LU   = NULL;
    cuComplex *I    = NULL;
    cuComplex *X    = NULL;
    cuComplex *Hdag = NULL;
    cuComplex *s    = NULL;
    cuComplex *W    = NULL;
    int *Ipiv = NULL;
    int *info = NULL;

//    struct dm_parms *dm_d;
    unsigned int *M_d;
    unsigned int *Td_k_d;
    float *Td_deg_d;
    float *d_d;
    float *P_d;
    float *B_d;
    float *Td_c_d;
    cuComplex *alpha_d, *beta_d, *scale_d;

    float *Td_d = NULL;
    cuComplex *H_Td_d = NULL;
    cuComplex *HHLU_d = NULL;
    cuComplex *IX_d   = NULL;
    cuComplex *work_d = NULL;
    cuComplex *Hdag_d = NULL;
    cuComplex *s_d  = NULL;
    cuComplex *W_d  = NULL;
    int *Ipiv_d = NULL;
    int *info_d = NULL;

    int lwork = 0;     /* size of workspace */

    cudaFree(0);
    startTime(&timer);

    // set up test case
//    dm_h      = (struct dm_parms *) malloc(sizeof(struct dm_parms));
    M = 2;
    d = 0.5;
    P = 1.0;
    B = 1.0;
    Td_c = PI / 180.0;
    Td_k = 2;
    Td_deg[0] = 45.0;
    Td_deg[1] = 120.0;
    alpha = make_cuFloatComplex(1., 0.);
    beta  = make_cuFloatComplex(0., 0.);
    scale = make_cuFloatComplex(B * sqrtf(P) / sqrtf(Td_k), 0.);

    // host allocations
    H_Td = (cuComplex *) malloc(sizeof(cuComplex) * M    * Td_k);
    HH   = (cuComplex *) malloc(sizeof(cuComplex) * Td_k * Td_k);
    LU   = (cuComplex *) malloc(sizeof(cuComplex) * Td_k * Td_k);
    I    = (cuComplex *) malloc(sizeof(cuComplex) * Td_k * Td_k);
    X    = (cuComplex *) malloc(sizeof(cuComplex) * Td_k * Td_k);
    Hdag = (cuComplex *) malloc(sizeof(cuComplex) * M    * Td_k);
    W    = (cuComplex *) malloc(sizeof(cuComplex) * M);
    Ipiv = (int *) malloc(sizeof(int) * Td_k);
    info = (int *) malloc(sizeof(int));

    stopTime(&timer); printf("Host Allocs:  %f s\n", elapsedTime(timer)); fflush(stdout); startTime(&timer);

    // set up device environment
    cudaError1 = cudaStreamCreateWithFlags(&cudaStream, cudaStreamNonBlocking);
    assert(cudaSuccess == cudaError1);

    cublasStatus = cublasCreate(&cublasHandle);
    assert(CUBLAS_STATUS_SUCCESS == cublasStatus);

    cublasStatus = cublasSetStream(cublasHandle, cudaStream);
    assert(CUBLAS_STATUS_SUCCESS == cublasStatus);

    cublasStatus = cublasSetPointerMode(cublasHandle, CUBLAS_POINTER_MODE_DEVICE);
    assert(CUBLAS_STATUS_SUCCESS == cublasStatus);

    cusolverStatus = cusolverDnCreate(&cusolverDnHandle);
    assert(CUSOLVER_STATUS_SUCCESS == cusolverStatus);

    cusolverStatus = cusolverDnSetStream(cusolverDnHandle, cudaStream);
    assert(CUSOLVER_STATUS_SUCCESS == cusolverStatus);

    stopTime(&timer); printf("Startups:  %f s\n", elapsedTime(timer)); fflush(stdout); startTime(&timer);

    // device allocations and parameter delivery
    // this is clearly why no one does this
    cudaError1 = cudaMalloc((void**)&M_d,      sizeof(unsigned int));
    assert(cudaSuccess == cudaError1);
    cudaError1 = cudaMalloc((void**)&Td_k_d,   sizeof(unsigned int));
    assert(cudaSuccess == cudaError1);
    cudaError1 = cudaMalloc((void**)&Td_deg_d, sizeof(float) * 64);
    assert(cudaSuccess == cudaError1);
    cudaError1 = cudaMalloc((void**)&d_d,      sizeof(float));
    assert(cudaSuccess == cudaError1);
    cudaError1 = cudaMalloc((void**)&P_d,      sizeof(float));
    assert(cudaSuccess == cudaError1);
    cudaError1 = cudaMalloc((void**)&B_d,      sizeof(float));
    assert(cudaSuccess == cudaError1);
    cudaError1 = cudaMalloc((void**)&Td_c_d,   sizeof(float));
    assert(cudaSuccess == cudaError1);
    cudaError1 = cudaMalloc((void**)&alpha_d,  sizeof(cuComplex));
    assert(cudaSuccess == cudaError1);
    cudaError1 = cudaMalloc((void**)&beta_d,   sizeof(cuComplex));
    assert(cudaSuccess == cudaError1);
    cudaError1 = cudaMalloc((void**)&scale_d,  sizeof(cuComplex));
    assert(cudaSuccess == cudaError1);

    cudaError1 = cudaMemcpyAsync(M_d, &M,          sizeof(unsigned int), cudaMemcpyHostToDevice, cudaStream);
    assert(cudaSuccess == cudaError1);
    cudaError1 = cudaMemcpyAsync(Td_k_d, &Td_k,    sizeof(unsigned int), cudaMemcpyHostToDevice, cudaStream);
    assert(cudaSuccess == cudaError1);
    cudaError1 = cudaMemcpyAsync(Td_deg_d, Td_deg, sizeof(float) * 64, cudaMemcpyHostToDevice, cudaStream);
    assert(cudaSuccess == cudaError1);
    cudaError1 = cudaMemcpyAsync(d_d, &d,          sizeof(float), cudaMemcpyHostToDevice, cudaStream);
    assert(cudaSuccess == cudaError1);
    cudaError1 = cudaMemcpyAsync(P_d, &P,          sizeof(float), cudaMemcpyHostToDevice, cudaStream);
    assert(cudaSuccess == cudaError1);
    cudaError1 = cudaMemcpyAsync(B_d, &B,          sizeof(float), cudaMemcpyHostToDevice, cudaStream);
    assert(cudaSuccess == cudaError1);
    cudaError1 = cudaMemcpyAsync(Td_c_d, &Td_c,    sizeof(float), cudaMemcpyHostToDevice, cudaStream);
    assert(cudaSuccess == cudaError1);
    cudaError1 = cudaMemcpyAsync(alpha_d, &alpha,  sizeof(cuComplex), cudaMemcpyHostToDevice, cudaStream);
    assert(cudaSuccess == cudaError1);
    cudaError1 = cudaMemcpyAsync(beta_d, &beta,    sizeof(cuComplex), cudaMemcpyHostToDevice, cudaStream);
    assert(cudaSuccess == cudaError1);
    cudaError1 = cudaMemcpyAsync(scale_d, &scale,  sizeof(cuComplex), cudaMemcpyHostToDevice, cudaStream);
    assert(cudaSuccess == cudaError1);

    cudaError1 = cudaMalloc((void**)&Td_d, sizeof(float) * 64);
    assert(cudaSuccess == cudaError1);

    stopTime(&timer); printf("Dev Allocs1:  %f s\n", elapsedTime(timer)); fflush(stdout); startTime(&timer);

    // calculate directions in radians (copy degrees, then scale vector)
    cublasStatus = cublasScopy(cublasHandle, Td_k, Td_deg_d, 1, Td_d, 1);
    assert(CUBLAS_STATUS_SUCCESS == cublasStatus);
    cublasStatus = cublasSscal(cublasHandle, Td_k, Td_c_d, Td_d, 1);
    assert(CUBLAS_STATUS_SUCCESS == cublasStatus);

    stopTime(&timer); printf("Dev Td:  %f s\n", elapsedTime(timer)); fflush(stdout); startTime(&timer);

    cudaError1 = cudaMalloc((void**)&H_Td_d, sizeof(cuComplex) * M    * Td_k);
    cudaError2 = cudaMalloc((void**)&HHLU_d, sizeof(cuComplex) * Td_k * Td_k);
    cudaError3 = cudaMalloc((void**)&IX_d,   sizeof(cuComplex) * Td_k * Td_k);
    cudaError4 = cudaMalloc((void**)&Hdag_d, sizeof(cuComplex) * M    * Td_k);
    assert(cudaSuccess == cudaError1);
    assert(cudaSuccess == cudaError2);
    assert(cudaSuccess == cudaError3);
    assert(cudaSuccess == cudaError4);
    cudaError1 = cudaMalloc((void**)&s_d,    sizeof(cuComplex) * Td_k);
    cudaError2 = cudaMalloc((void**)&W_d,    sizeof(cuComplex) * M);
    assert(cudaSuccess == cudaError1);
    assert(cudaSuccess == cudaError2);

    cudaError1 = cudaMalloc((void**)&Ipiv_d, sizeof(int) * Td_k);
    cudaError2 = cudaMalloc((void**)&info_d, sizeof(int));
    assert(cudaSuccess == cudaError1);
    assert(cudaSuccess == cudaError2);

    stopTime(&timer); printf("Dev Allocs 2:  %f s\n", elapsedTime(timer)); fflush(stdout); startTime(&timer);

    // invoke kernel to construct steering matrix
    dim3 steeringgridDim((Td_k + STEERING_BLOCK_SIZE - 1) / STEERING_BLOCK_SIZE, (M + STEERING_BLOCK_SIZE - 1) / STEERING_BLOCK_SIZE, 1);
    dim3 steeringblockDim(STEERING_BLOCK_SIZE, STEERING_BLOCK_SIZE, 1);
    steering<<<steeringgridDim, steeringblockDim, 0, cudaStream>>>(M, Td_k, d, Td_d, H_Td_d);

    stopTime(&timer); printf("H_Td kernel:  %f s\n", elapsedTime(timer)); fflush(stdout); startTime(&timer);

//    // this is for testing and intended to be temporary...
//    cudaError1 = cudaDeviceSynchronize();
//    assert(cudaSuccess == cudaError1);
//
//    cudaError1 = cudaMemcpy(H_Td, H_Td_d, sizeof(cuComplex) * M * Td_k, cudaMemcpyDeviceToHost);
//    assert(cudaSuccess == cudaError1);
//
//    printf("H =\n");
//    printMatrix(M, Td_k, H_Td, M, "H");
//    printf("=====\n");

// The next step is to form the matrix that will be inverted.  This
// matrix is formed by calculating dm_H_Td^H * dm_H_Td; that is, the
// the conjugate transpose of dm_H_Td is multiplied by dm_H_Td.
// This matrix multiplication is unusual because it can be done
// without explicitly forming the conjugate transpose; the only catch
// is that the matrix multiply is somewhat nonstandard, although it
// might be worth investigating whether options exist to form the
// conjugate transpose on the fly.  The resulting matrix was called
// dm_H_Td_H_Td originally, but for brevity is being shortened to
// something more along the lines of dm_HH_h.

    cublasStatus = cublasCgemm(cublasHandle, CUBLAS_OP_C, CUBLAS_OP_N, Td_k, Td_k, M, alpha_d, H_Td_d, M, H_Td_d, M, beta_d, HHLU_d, Td_k);
    assert(CUBLAS_STATUS_SUCCESS == cublasStatus);

    stopTime(&timer); printf("H'H Cgemm:  %f s\n", elapsedTime(timer)); fflush(stdout); startTime(&timer);

//    // this is for testing and intended to be temporary...
//    cudaError1 = cudaDeviceSynchronize();
//    assert(cudaSuccess == cudaError1);
//
//    cudaError1 = cudaMemcpy(HH, HHLU_d, sizeof(cuComplex) * Td_k * Td_k, cudaMemcpyDeviceToHost);
//    assert(cudaSuccess == cudaError1);
//
//    printf("H'H =\n");
//    printMatrix(Td_k, Td_k, HH, Td_k, "H'H");
//    printf("=====\n");

// an inverse is now required, so do the setup to get that going

/* step 3: query working space of getrf */
    cusolverStatus = cusolverDnCgetrf_bufferSize(
        cusolverDnHandle,
        Td_k,
        Td_k,
        HHLU_d,
        Td_k,
        &lwork);
    assert(CUSOLVER_STATUS_SUCCESS == cusolverStatus);

    cudaError1 = cudaMalloc((void**)&work_d, sizeof(cuComplex) * lwork);
    assert(cudaSuccess == cudaError1);

/* step 4: LU factorization */
    cusolverStatus = cusolverDnCgetrf(
        cusolverDnHandle,
        Td_k,
        Td_k,
        HHLU_d,
        Td_k,
        work_d,
        Ipiv_d,
        info_d);
//    cudaError1 = cudaDeviceSynchronize();
    assert(CUSOLVER_STATUS_SUCCESS == cusolverStatus);
//    assert(cudaSuccess == cudaError1);

    stopTime(&timer); printf("LU:  %f s\n", elapsedTime(timer)); fflush(stdout); startTime(&timer);

//    // async? still needed at all?
//    cudaError1 = cudaMemcpy(LU, HHLU_d, sizeof(cuComplex) * Td_k * Td_k, cudaMemcpyDeviceToHost);
//    cudaError2 = cudaMemcpy(Ipiv, Ipiv_d, sizeof(int) * Td_k, cudaMemcpyDeviceToHost);
//    cudaError3 = cudaMemcpy(info, info_d, sizeof(int), cudaMemcpyDeviceToHost);
//    assert(cudaSuccess == cudaError1);
//    assert(cudaSuccess == cudaError2);
//    assert(cudaSuccess == cudaError3);
//
//    if ( 0 > *info ){
//        printf("%d-th parameter is wrong \n", -*info);
//        exit(1);
//    }
//    printf("pivoting sequence, matlab base-1\n");
//    for(int j = 0 ; j < Td_k ; j++){
//        printf("Ipiv(%d) = %d\n", j+1, Ipiv[j]);
//    }
//    printf("L and U = (matlab base-1)\n");
//    printMatrix(Td_k, Td_k, LU, Td_k, "LU");
//    printf("=====\n");

// side step:  need an identiy matrix - was B before, will be X on device after solve
// so, also need a place for X to come back to on host

    // invoke kernel to construct complex identity matrix
    dim3 CidentgridDim((Td_k + CIDENT_BLOCK_SIZE - 1) / CIDENT_BLOCK_SIZE, (Td_k + CIDENT_BLOCK_SIZE - 1) / CIDENT_BLOCK_SIZE, 1);
    dim3 CidentblockDim(CIDENT_BLOCK_SIZE, CIDENT_BLOCK_SIZE, 1);
    Cident<<<CidentgridDim, CidentblockDim, 0, cudaStream>>>(Td_k, IX_d);

    stopTime(&timer); printf("I:  %f s\n", elapsedTime(timer)); fflush(stdout); startTime(&timer);

/*
 * step 5: solve A*X = I
 * ????
 *
 */
    cusolverStatus = cusolverDnCgetrs(
        cusolverDnHandle,
        CUBLAS_OP_N,
        Td_k,
        Td_k, /* nrhs */
        HHLU_d, // this is now LU factored
        Td_k,
        Ipiv_d,
        IX_d,   // solution overwrites identity
        Td_k,
        info_d);
//    cudaError1 = cudaDeviceSynchronize();
    assert(CUSOLVER_STATUS_SUCCESS == cusolverStatus);
//    assert(cudaSuccess == cudaError1);

    stopTime(&timer); printf("Inverse:  %f s\n", elapsedTime(timer)); fflush(stdout); startTime(&timer);

//    cudaError1 = cudaMemcpy(X , IX_d, sizeof(cuComplex) * Td_k * Td_k, cudaMemcpyDeviceToHost);
//    assert(cudaSuccess == cudaError1);
//
//    printf("(H'H)^-1 = (matlab base-1)\n");
//    printMatrix(Td_k, Td_k, X, Td_k, "(H'H)^-1");
//    printf("=====\n");

// The next step is to form the pseudoinverse.  This matrix is formed
// by multiplying the steering matrix by the inverse just calculated.
// The steering matrix is generally not square, but the inverse is.
// They share inner dimensions so this is a regular matrix multiply.

    cublasStatus = cublasCgemm(cublasHandle, CUBLAS_OP_N, CUBLAS_OP_N, M, Td_k, Td_k, alpha_d, H_Td_d, M, IX_d, Td_k, beta_d, Hdag_d, M);
    assert(CUBLAS_STATUS_SUCCESS == cublasStatus);

    stopTime(&timer); printf("Pseudoinverse:  %f s\n", elapsedTime(timer)); fflush(stdout); startTime(&timer);

//    // this is for testing and intended to be temporary...
//    cudaError1 = cudaDeviceSynchronize();
//    assert(cudaSuccess == cudaError1);
//
//    cudaError1 = cudaMemcpy(Hdag, Hdag_d, sizeof(cuComplex) * M * Td_k, cudaMemcpyDeviceToHost);
//    assert(cudaSuccess == cudaError1);
//
//    printf("Hdag =\n");
//    printMatrix(M, Td_k, Hdag, M, "Hdag");
//    printf("=====\n");

// The next step is to calculate the baseband weights, which is a
// matrix*vector multiplication.  The result also has to be scaled.

    s    = (cuComplex *) malloc(sizeof(cuComplex) * Td_k);
    s[0] = make_cuFloatComplex( 1., 0.);
    s[1] = make_cuFloatComplex(-1., 0.);

    cudaError1 = cudaMemcpyAsync(s_d, s,          sizeof(cuComplex) * Td_k, cudaMemcpyHostToDevice, cudaStream);
    assert(cudaSuccess == cudaError1);

    cublasStatus = cublasCgemv(cublasHandle, CUBLAS_OP_N, M, Td_k, scale_d, Hdag_d, M, s_d, 1, beta_d, W_d, 1);
    assert(CUBLAS_STATUS_SUCCESS == cublasStatus);

    stopTime(&timer); printf("W:  %f s\n", elapsedTime(timer)); fflush(stdout); startTime(&timer);

    // this is for testing and intended to be temporary...
    cudaError1 = cudaDeviceSynchronize();
    assert(cudaSuccess == cudaError1);

    cudaError1 = cudaMemcpy(W, W_d, sizeof(cuComplex) * M, cudaMemcpyDeviceToHost);
    assert(cudaSuccess == cudaError1);

    stopTime(&timer); printf("W Retrieved:  %f s\n", elapsedTime(timer)); fflush(stdout); startTime(&timer);

    printf("W =\n");
    printMatrix(M, 1, W, M, "W");
    printf("=====\n");

    // free resources, shut down environment
//    if (dm_d  ) cudaFree(dm_d);
    if (Td_d  ) cudaFree(Td_d);
    if (H_Td_d) cudaFree(H_Td_d);
    if (HHLU_d) cudaFree(HHLU_d);
    if (IX_d  ) cudaFree(IX_d);
    if (work_d) cudaFree(work_d);
    if (Hdag_d) cudaFree(Hdag_d);
    if (s_d   ) cudaFree(s_d);
    if (W_d   ) cudaFree(W_d);
    if (Ipiv_d) cudaFree(Ipiv_d);
    if (info_d) cudaFree(info_d);

    if (cusolverDnHandle) cusolverDnDestroy(cusolverDnHandle);
    if (cublasHandle)     cublasDestroy(cublasHandle);
    if (cudaStream)       cudaStreamDestroy(cudaStream);

    cudaDeviceReset();

//    if (dm_h     ) free(dm_h     );
//    if (dm_Td    ) free(dm_Td    );
    if (H_Td) free(H_Td);
    if (HH  ) free(HH  );
    if (LU  ) free(LU  );
    if (I   ) free(I   );
    if (X   ) free(X   );
    if (Hdag) free(Hdag);
    if (s   ) free(s   );
    if (W   ) free(W   );
    if (Ipiv) free(Ipiv);
    if (info) free(info);

    return 0;
}

