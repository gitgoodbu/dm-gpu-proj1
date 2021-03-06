#include <stdio.h>
#include <stdlib.h>
#include <assert.h>
#include <cuda_runtime.h>
#include <cusolverDn.h>
#include <cuComplex.h>

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

#define PI 3.141592653589793238462643383279502884197169399375105820974

struct dm_parms {
    int M;    // number of antenna elements
    float d;  // spacing of antenna elements, in wavelengths
    float P;  // average power, presumably Watts, typically 1 for sims
    float B;  // beta 1; power allocation; 1 if not using null space
    int Td_k; // number of Td elements used, i.e., # of directions
    float Td_deg[64]; // specified directions in degrees; Theta_d
};

void printMatrix(int m, int n, const cuComplex *A, int lda, const char *name)
{
    for(int row = 0 ; row < m ; row++){
        for(int col = 0 ; col < n ; col++){
            cuComplex Areg = A[row + col*lda];
            printf("%s(%d,%d) = %f%+fi\n", name, row+1, col+1, cuCrealf(Areg), cuCimagf(Areg));
        }
    }
}

int main(int argc, char *argv[])
{
    Timer timer;

    cusolverDnHandle_t cusolverH = NULL;
    cudaStream_t stream = NULL;

    cusolverStatus_t status = CUSOLVER_STATUS_SUCCESS;
    cudaError_t cudaStat1 = cudaSuccess;
    cudaError_t cudaStat2 = cudaSuccess;
    cudaError_t cudaStat3 = cudaSuccess;
    cudaError_t cudaStat4 = cudaSuccess;

    struct dm_parms *dm_h;
    float *dm_Td;
    cuComplex *dm_H_Td_h = NULL;
    cuComplex *dm_HH_h   = NULL;
    cuComplex *dm_LU_h   = NULL;
    cuComplex *dm_I_h    = NULL;
    cuComplex *dm_X_h    = NULL;
    cuComplex *dm_Hdag_h = NULL;
    cuComplex *dm_s      = NULL;
    cuComplex *dm_W      = NULL;
    int *Ipiv_h = NULL;
    int *info_h = NULL;

    cuComplex *dm_HHLU_d = NULL;
    cuComplex *dm_IX_d   = NULL;
    cuComplex *work_d    = NULL;
    int *Ipiv_d = NULL;
    int *info_d = NULL;

    int i, j, k, index;
    float norm, arg;
    cuComplex sum, scale;
    int  lwork = 0;     /* size of workspace */

    cudaFree(0);
    startTime(&timer);

    dm_h      = (struct dm_parms *) malloc(sizeof(struct dm_parms));
    dm_Td     = (float *) malloc(sizeof(float) * 64);

    dm_h->M = 2;
    dm_h->d = 0.5;
    dm_h->P = 1.0;
    dm_h->B = 1.0;
    dm_h->Td_k = 2;
    dm_h->Td_deg[0] = 45.0;
    dm_h->Td_deg[1] = 120.0;

    for (i = 0; i < dm_h->Td_k; i++)
        dm_Td[i] = dm_h->Td_deg[i] * PI / 180.0;

    dm_s      = (cuComplex *) malloc(sizeof(cuComplex) * dm_h->Td_k);
    dm_s[0] = make_cuFloatComplex(1., 0.);
    dm_s[1] = make_cuFloatComplex(-1., 0.);

    dm_H_Td_h = (cuComplex *) malloc(sizeof(cuComplex) * dm_h->M    * dm_h->Td_k);
    dm_HH_h   = (cuComplex *) malloc(sizeof(cuComplex) * dm_h->Td_k * dm_h->Td_k);
    dm_LU_h   = (cuComplex *) malloc(sizeof(cuComplex) * dm_h->Td_k * dm_h->Td_k);
    dm_I_h    = (cuComplex *) malloc(sizeof(cuComplex) * dm_h->Td_k * dm_h->Td_k);
    dm_X_h    = (cuComplex *) malloc(sizeof(cuComplex) * dm_h->Td_k * dm_h->Td_k);
    dm_Hdag_h = (cuComplex *) malloc(sizeof(cuComplex) * dm_h->M    * dm_h->Td_k);
    dm_W      = (cuComplex *) malloc(sizeof(cuComplex) * dm_h->M);
    Ipiv_h    = (int *) malloc(sizeof(int) * dm_h->Td_k);
    info_h    = (int *) malloc(sizeof(int));

    cudaStat1 = cudaMalloc ((void**)&dm_HHLU_d, sizeof(cuComplex) * dm_h->Td_k * dm_h->Td_k);
    cudaStat2 = cudaMalloc ((void**)&dm_IX_d,   sizeof(cuComplex) * dm_h->Td_k * dm_h->Td_k);
    cudaStat3 = cudaMalloc ((void**)&Ipiv_d, sizeof(int) * dm_h->Td_k);
    cudaStat4 = cudaMalloc ((void**)&info_d, sizeof(int));
    assert(cudaSuccess == cudaStat1);
    assert(cudaSuccess == cudaStat2);
    assert(cudaSuccess == cudaStat3);
    assert(cudaSuccess == cudaStat4);

    stopTime(&timer); printf("Allocs:  %f s\n", elapsedTime(timer)); startTime(&timer);

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

    norm = 1 / sqrtf(dm_h->M);
    for (i = 0; i < dm_h->M; i++)
        for (j = 0; j < dm_h->Td_k; j++) {
            arg = 2 * PI * dm_h->d * i * cosf(dm_Td[j]);
            index = j * dm_h->M + i;
            sincosf(arg, &dm_H_Td_h[index].y, &dm_H_Td_h[index].x);
            dm_H_Td_h[index].x *= norm;
            dm_H_Td_h[index].y *= -norm;
//            printf("i = %d, j = %d, arg = %f, index = %d, .x = %f, .y = %f\n", i, j, arg, index, dm_H_Td_h[index].x, dm_H_Td_h[index].y);
        }

    stopTime(&timer); printf("H:  %f s\n", elapsedTime(timer)); startTime(&timer);

//    printf("H =\n");
//    printMatrix(dm_h->M, dm_h->Td_k, dm_H_Td_h, dm_h->M, "H");
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

    for (i = 0; i < dm_h->Td_k; i++)
        for (j = 0; j < dm_h->Td_k; j++) {
            sum.x = sum.y = 0.0;
            for (k = 0; k < dm_h->M; k++)
                sum = cuCaddf(sum, cuCmulf(cuConjf(dm_H_Td_h[i * dm_h->M + k]), dm_H_Td_h[j * dm_h->M + k]));
            dm_HH_h[j * dm_h->M + i] = sum;
        }

    stopTime(&timer); printf("H'H:  %f s\n", elapsedTime(timer)); startTime(&timer);

//    printf("H'H =\n");
//    printMatrix(dm_h->Td_k, dm_h->Td_k, dm_HH_h, dm_h->Td_k, "H'H");
//    printf("=====\n");

// an inverse is now required, so do the setup to get that going

/* step 1: create cusolver handle, bind a stream */
    status = cusolverDnCreate(&cusolverH);
    assert(CUSOLVER_STATUS_SUCCESS == status);

    cudaStat1 = cudaStreamCreateWithFlags(&stream, cudaStreamNonBlocking);
    assert(cudaSuccess == cudaStat1);

    status = cusolverDnSetStream(cusolverH, stream);
    assert(CUSOLVER_STATUS_SUCCESS == status);

    stopTime(&timer); printf("Solver Startup:  %f s\n", elapsedTime(timer)); startTime(&timer);

/* step 2: copy HH to device */

    cudaStat1 = cudaMemcpy(dm_HHLU_d, dm_HH_h, sizeof(cuComplex) * dm_h->Td_k * dm_h->Td_k, cudaMemcpyHostToDevice);
    assert(cudaSuccess == cudaStat1);

    stopTime(&timer); printf("H'H copy:  %f s\n", elapsedTime(timer)); startTime(&timer);

/* step 3: query working space of getrf */
    status = cusolverDnCgetrf_bufferSize(
        cusolverH,
        dm_h->Td_k,
        dm_h->Td_k,
        dm_HHLU_d,
        dm_h->Td_k,
        &lwork);
    assert(CUSOLVER_STATUS_SUCCESS == status);

    cudaStat1 = cudaMalloc((void**)&work_d, sizeof(cuComplex) * lwork);
    assert(cudaSuccess == cudaStat1);

    stopTime(&timer); printf("mid alloc:  %f s\n", elapsedTime(timer)); startTime(&timer);

/* step 4: LU factorization */
    status = cusolverDnCgetrf(
        cusolverH,
        dm_h->Td_k,
        dm_h->Td_k,
        dm_HHLU_d,
        dm_h->Td_k,
        work_d,
        Ipiv_d,
        info_d);
    cudaStat1 = cudaDeviceSynchronize();
    assert(CUSOLVER_STATUS_SUCCESS == status);
    assert(cudaSuccess == cudaStat1);

    stopTime(&timer); printf("LU:  %f s\n", elapsedTime(timer)); startTime(&timer);

    cudaStat1 = cudaMemcpy(dm_LU_h, dm_HHLU_d, sizeof(cuComplex) * dm_h->Td_k * dm_h->Td_k, cudaMemcpyDeviceToHost);
    cudaStat2 = cudaMemcpy(Ipiv_h, Ipiv_d, sizeof(int) * dm_h->Td_k, cudaMemcpyDeviceToHost);
    cudaStat3 = cudaMemcpy(info_h, info_d, sizeof(int), cudaMemcpyDeviceToHost);
    assert(cudaSuccess == cudaStat1);
    assert(cudaSuccess == cudaStat2);
    assert(cudaSuccess == cudaStat3);

    stopTime(&timer); printf("LU copy:  %f s\n", elapsedTime(timer)); startTime(&timer);

    if ( 0 > *info_h ){
//        printf("%d-th parameter is wrong \n", -*info_h);
        exit(1);
    }
//    printf("pivoting sequence, matlab base-1\n");
//    for(int j = 0 ; j < dm_h->Td_k ; j++){
//        printf("Ipiv_h(%d) = %d\n", j+1, Ipiv_h[j]);
//    }
//    printf("L and U = (matlab base-1)\n");
//    printMatrix(dm_h->Td_k, dm_h->Td_k, dm_LU_h, dm_h->Td_k, "LU");
//    printf("=====\n");

// side step:  need an identiy matrix - was B before, will be X on device after solve
// so, also need a place for X to come back to on host

    for (i = 0; i < dm_h->Td_k; i++)
        for (j = 0; j < dm_h->Td_k; j++)
            dm_I_h[j * dm_h->Td_k + i] = (i == j) ? make_cuFloatComplex(1., 0.) : make_cuFloatComplex(0., 0.);

    cudaStat1 = cudaMemcpy(dm_IX_d, dm_I_h, sizeof(cuComplex) * dm_h->Td_k * dm_h->Td_k, cudaMemcpyHostToDevice);
    assert(cudaSuccess == cudaStat1);

    stopTime(&timer); printf("I copy:  %f s\n", elapsedTime(timer)); startTime(&timer);

/*
 * step 5: solve A*X = I
 * ????
 *
 */
    status = cusolverDnCgetrs(
        cusolverH,
        CUBLAS_OP_N,
        dm_h->Td_k,
        dm_h->Td_k, /* nrhs */
        dm_HHLU_d, // this is now LU factored
        dm_h->Td_k,
        Ipiv_d,
        dm_IX_d,   // solution overwrites identity
        dm_h->Td_k,
        info_d);
    cudaStat1 = cudaDeviceSynchronize();
    assert(CUSOLVER_STATUS_SUCCESS == status);
    assert(cudaSuccess == cudaStat1);

    stopTime(&timer); printf("Inverse:  %f s\n", elapsedTime(timer)); startTime(&timer);

    cudaStat1 = cudaMemcpy(dm_X_h , dm_IX_d, sizeof(cuComplex) * dm_h->Td_k * dm_h->Td_k, cudaMemcpyDeviceToHost);
    assert(cudaSuccess == cudaStat1);

    stopTime(&timer); printf("Inverse copy:  %f s\n", elapsedTime(timer)); startTime(&timer);

//    printf("(H'H)^-1 = (matlab base-1)\n");
//    printMatrix(dm_h->Td_k, dm_h->Td_k, dm_X_h, dm_h->Td_k, "(H'H)^-1");
//    printf("=====\n");

// The next step is to form the pseudoinverse.  This matrix is formed
// by multiplying the steering matrix by the inverse just calculated.
// The steering matrix is generally not square, but the inverse is.
// They share inner dimensions so this is a regular matrix multiply.

    for (i = 0; i < dm_h->M; i++)
        for (j = 0; j < dm_h->Td_k; j++) {
            sum.x = sum.y = 0.0;
            for (k = 0; k < dm_h->Td_k; k++)
                sum = cuCaddf(sum, cuCmulf(dm_H_Td_h[k * dm_h->M + i] , dm_X_h[j * dm_h->Td_k + k]));
            dm_Hdag_h[j * dm_h->M + i] = sum;
        }

    stopTime(&timer); printf("Hdag:  %f s\n", elapsedTime(timer)); startTime(&timer);

//    printf("Hdag =\n");
//    printMatrix(dm_h->M, dm_h->Td_k, dm_Hdag_h, dm_h->M, "Hdag");
//    printf("=====\n");

// The next step is to calculate the baseband weights, which is a
// matrix*vector multiplication.  The result also has to be scaled.

    scale = make_cuFloatComplex(dm_h->B * sqrtf(dm_h->P) / sqrtf(dm_h->Td_k), 0.);
    for (i = 0; i < dm_h->M; i++)
        for (j = 0; j < 1; j++) {
            sum.x = sum.y = 0.0;
            for (k = 0; k < dm_h->Td_k; k++)
                sum = cuCaddf(sum, cuCmulf(dm_Hdag_h[k * dm_h->M + i] , dm_s[j * dm_h->Td_k + k]));
            dm_W[j * dm_h->M + i] = cuCmulf(scale, sum);
        }

    stopTime(&timer); printf("Weights:  %f s\n", elapsedTime(timer)); startTime(&timer);

//    printf("W =\n");
//    printMatrix(dm_h->M, 1, dm_W, dm_h->M, "W");
//    printf("=====\n");

/* free resources */

    if (dm_HHLU_d) cudaFree(dm_HHLU_d);
    if (dm_IX_d  ) cudaFree(dm_IX_d);
    if (Ipiv_d   ) cudaFree(Ipiv_d);
    if (info_d   ) cudaFree(info_d);
    if (work_d   ) cudaFree(work_d);

    if (cusolverH) cusolverDnDestroy(cusolverH);
    if (stream   ) cudaStreamDestroy(stream);

    cudaDeviceReset();

    if (dm_h     ) free(dm_h     );
    if (dm_Td    ) free(dm_Td    );
    if (dm_s     ) free(dm_s     );
    if (dm_H_Td_h) free(dm_H_Td_h);
    if (dm_HH_h  ) free(dm_HH_h  );
    if (dm_LU_h  ) free(dm_LU_h  );
    if (dm_I_h   ) free(dm_I_h   );
    if (dm_X_h   ) free(dm_X_h   );
    if (dm_Hdag_h) free(dm_Hdag_h);
    if (dm_W     ) free(dm_W     );
    if (Ipiv_h   ) free(Ipiv_h   );
    if (info_h   ) free(info_h   );

    stopTime(&timer); printf("Dealloc:  %f s\n", elapsedTime(timer));

    return 0;
}

