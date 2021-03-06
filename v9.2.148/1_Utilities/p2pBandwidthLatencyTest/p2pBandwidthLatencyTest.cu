/*
 * Copyright 1993-2015 NVIDIA Corporation.  All rights reserved.
 *
 * Please refer to the NVIDIA end user license agreement (EULA) associated
 * with this source code for terms and conditions that govern your use of
 * this software. Any use, reproduction, disclosure, or distribution of
 * this software and related documentation outside the terms of the EULA
 * is strictly prohibited.
 *
 */

#include <cstdio>
#include <vector>

#include <helper_cuda.h>
#include <helper_timer.h>

using namespace std;

const char *sSampleName = "P2P (Peer-to-Peer) GPU Bandwidth Latency Test";

typedef enum
{
    P2P_WRITE = 0, 
    P2P_READ = 1,
}P2PDataTransfer;

//Macro for checking cuda errors following a cuda launch or api call
#define cudaCheckError() {                                          \
        cudaError_t e=cudaGetLastError();                                 \
        if(e!=cudaSuccess) {                                              \
            printf("Cuda failure %s:%d: '%s'\n",__FILE__,__LINE__,cudaGetErrorString(e));           \
            exit(EXIT_FAILURE);                                           \
        }                                                                 \
    }
__global__ void delay(volatile int *flag, unsigned long long timeout_ns = 10000000000)
{
    // Wait until the application notifies us that it has completed queuing up the
    // experiment, or timeout and exit, allowing the application to make progress
    register unsigned long long start_time, sample_time;
    asm("mov.u64 %0, %%globaltimer;" : "=l"(start_time));
    while (!*flag) {
        asm("mov.u64 %0, %%globaltimer;" : "=l"(sample_time));
        if (sample_time - start_time > timeout_ns) {
            break;
        }
    }
}

///////////////////////////////////////////////////////////////////////////
//Print help screen
///////////////////////////////////////////////////////////////////////////
void printHelp(void)
{
    printf("Usage:  p2pBandwidthLatencyTest [OPTION]...\n");
    printf("Tests bandwidth/latency of GPU pairs using P2P and without P2P\n");
    printf("\n");

    printf("Options:\n");
    printf("--help\t\tDisplay this help menu\n");
    printf("--p2p_read\tUse P2P reads for data transfers between GPU pairs and show corresponding results.\n \t\tDefault used is P2P write operation.\n");
}

void checkP2Paccess(int numGPUs)
{
    for (int i = 0; i < numGPUs; i++) {
        cudaSetDevice(i);
        cudaCheckError();

        for (int j = 0; j < numGPUs; j++) {
            int access;
            if (i != j) {
                cudaDeviceCanAccessPeer(&access, i, j);
                cudaCheckError();
                printf("Device=%d %s Access Peer Device=%d\n", i, access ? "CAN" : "CANNOT", j);
            }
        }
    }
    printf("\n***NOTE: In case a device doesn't have P2P access to other one, it falls back to normal memcopy procedure.\nSo you can see lesser Bandwidth (GB/s) and unstable Latency (us) in those cases.\n\n");
}

void outputBandwidthMatrix(int numGPUs, bool p2p, P2PDataTransfer p2p_method)
{
    int numElems = 10000000;
    int repeat = 5;
    volatile int *flag = NULL;
    vector<int *> buffers(numGPUs);
    vector<int *> buffersD2D(numGPUs); // buffer for D2D, that is, intra-GPU copy
    vector<cudaEvent_t> start(numGPUs);
    vector<cudaEvent_t> stop(numGPUs);
    vector<cudaStream_t> stream(numGPUs);

    cudaHostAlloc((void **)&flag, sizeof(*flag), cudaHostAllocPortable);
    cudaCheckError();

    for (int d = 0; d < numGPUs; d++) {
        cudaSetDevice(d);
        cudaStreamCreateWithFlags(&stream[d], cudaStreamNonBlocking);
        cudaMalloc(&buffers[d], numElems * sizeof(int));
        cudaCheckError();
        cudaMalloc(&buffersD2D[d], numElems * sizeof(int));
        cudaCheckError();
        cudaEventCreate(&start[d]);
        cudaCheckError();
        cudaEventCreate(&stop[d]);
        cudaCheckError();
    }

    vector<double> bandwidthMatrix(numGPUs * numGPUs);

    for (int i = 0; i < numGPUs; i++) {
        cudaSetDevice(i);

        for (int j = 0; j < numGPUs; j++) {
            int access;
            if (p2p) {
                cudaDeviceCanAccessPeer(&access, i, j);
                if (access) {
                    cudaDeviceEnablePeerAccess(j, 0 );
                    cudaCheckError();
                    cudaSetDevice(j);
                    cudaCheckError();
                    cudaDeviceEnablePeerAccess(i, 0 );
                    cudaCheckError();
                    cudaSetDevice(i);
                    cudaCheckError();
                }
            }

            cudaStreamSynchronize(stream[i]);
            cudaCheckError();

            // Block the stream until all the work is queued up
            // DANGER! - cudaMemcpy*Async may infinitely block waiting for
            // room to push the operation, so keep the number of repeatitions
            // relatively low.  Higher repeatitions will cause the delay kernel
            // to timeout and lead to unstable results.
            *flag = 0;
            delay<<< 1, 1, 0, stream[i]>>>(flag);
            cudaCheckError();
            cudaEventRecord(start[i], stream[i]);
            cudaCheckError();

            if (i == j) {
                // Perform intra-GPU, D2D copies
                for (int r = 0; r < repeat; r++) {
                    cudaMemcpyPeerAsync(buffers[i], i, buffersD2D[i], i, sizeof(int)*numElems, stream[i]);
                }
            }
            else {
                if (p2p_method == P2P_WRITE)
                {
                    for (int r = 0; r < repeat; r++) {
                         // Perform P2P writes
                        cudaMemcpyPeerAsync(buffers[j], j, buffers[i], i, sizeof(int)*numElems, stream[i]);
                    }
                }
                else
                {
                    for (int r = 0; r < repeat; r++) {
                        // Perform P2P reads
                        cudaMemcpyPeerAsync(buffers[i], i, buffers[j], j, sizeof(int)*numElems, stream[i]);
                    }
                }
            }

            cudaEventRecord(stop[i], stream[i]);
            cudaCheckError();

            // Release the queued events
            *flag = 1;
            cudaStreamSynchronize(stream[i]);
            cudaCheckError();

            float time_ms;
            cudaEventElapsedTime(&time_ms, start[i], stop[i]);
            double time_s = time_ms / 1e3;

            double gb = numElems * sizeof(int) * repeat / (double)1e9;
            if (i == j) {
                gb *= 2;    //must count both the read and the write here
            }
            bandwidthMatrix[i * numGPUs + j] = gb / time_s;
            if (p2p && access) {
                cudaDeviceDisablePeerAccess(j);
                cudaSetDevice(j);
                cudaDeviceDisablePeerAccess(i);
                cudaSetDevice(i);
                cudaCheckError();
            }
        }
    }

    printf("   D\\D");

    for (int j = 0; j < numGPUs; j++) {
        printf("%6d ", j);
    }

    printf("\n");

    for (int i = 0; i < numGPUs; i++) {
        printf("%6d ", i);

        for (int j = 0; j < numGPUs; j++) {
            printf("%6.02f ", bandwidthMatrix[i * numGPUs + j]);
        }

        printf("\n");
    }

    for (int d = 0; d < numGPUs; d++) {
        cudaSetDevice(d);
        cudaFree(buffers[d]);
        cudaFree(buffersD2D[d]);
        cudaCheckError();
        cudaEventDestroy(start[d]);
        cudaCheckError();
        cudaEventDestroy(stop[d]);
        cudaCheckError();
        cudaStreamDestroy(stream[d]);
        cudaCheckError();
    }

    cudaFreeHost((void *)flag);
    cudaCheckError();
}

void outputBidirectionalBandwidthMatrix(int numGPUs, bool p2p)
{
    int numElems = 10000000;
    int repeat = 5;
    volatile int *flag = NULL;
    vector<int *> buffers(numGPUs);
    vector<int *> buffersD2D(numGPUs);
    vector<cudaEvent_t> start(numGPUs);
    vector<cudaEvent_t> stop(numGPUs);
    vector<cudaStream_t> stream0(numGPUs);
    vector<cudaStream_t> stream1(numGPUs);

    cudaHostAlloc((void **)&flag, sizeof(*flag), cudaHostAllocPortable);
    cudaCheckError();

    for (int d = 0; d < numGPUs; d++) {
        cudaSetDevice(d);
        cudaMalloc(&buffers[d], numElems * sizeof(int));
        cudaMalloc(&buffersD2D[d], numElems * sizeof(int));
        cudaCheckError();
        cudaEventCreate(&start[d]);
        cudaCheckError();
        cudaEventCreate(&stop[d]);
        cudaCheckError();
        cudaStreamCreateWithFlags(&stream0[d], cudaStreamNonBlocking);
        cudaCheckError();
        cudaStreamCreateWithFlags(&stream1[d], cudaStreamNonBlocking);
        cudaCheckError();
    }

    vector<double> bandwidthMatrix(numGPUs * numGPUs);

    for (int i = 0; i < numGPUs; i++) {
        cudaSetDevice(i);

        for (int j = 0; j < numGPUs; j++) {
            int access;
            if (p2p) {
                cudaDeviceCanAccessPeer(&access, i, j);
                if (access) {
                    cudaSetDevice(i);
                    cudaDeviceEnablePeerAccess(j, 0);
                    cudaCheckError();
                    cudaSetDevice(j);
                    cudaDeviceEnablePeerAccess(i, 0);
                    cudaCheckError();
                }
            }


            cudaSetDevice(i);
            cudaStreamSynchronize(stream0[i]);
            cudaStreamSynchronize(stream1[j]);
            cudaCheckError();

            // Block the stream until all the work is queued up
            // DANGER! - cudaMemcpy*Async may infinitely block waiting for
            // room to push the operation, so keep the number of repeatitions
            // relatively low.  Higher repeatitions will cause the delay kernel
            // to timeout and lead to unstable results.
            *flag = 0;
            cudaSetDevice(i);
            // No need to block stream1 since it'll be blocked on stream0's event
            delay<<< 1, 1, 0, stream0[i]>>>(flag);
            cudaCheckError();

            // Force stream1 not to start until stream0 does, in order to ensure
            // the events on stream0 fully encompass the time needed for all operations
            cudaEventRecord(start[i], stream0[i]);
            cudaStreamWaitEvent(stream1[j], start[i], 0);

            if (i == j) {
                // For intra-GPU perform 2 memcopies buffersD2D <-> buffers
                for (int r = 0; r < repeat; r++) {
                    cudaMemcpyPeerAsync(buffers[i], i, buffersD2D[i], i, sizeof(int)*numElems, stream0[i]);
                    cudaMemcpyPeerAsync(buffersD2D[i], i, buffers[i], i, sizeof(int)*numElems, stream1[i]);
                }
            }
            else {
                for (int r = 0; r < repeat; r++) {
                    cudaMemcpyPeerAsync(buffers[i], i, buffers[j], j, sizeof(int)*numElems, stream1[j]);
                    cudaMemcpyPeerAsync(buffers[j], j, buffers[i], i, sizeof(int)*numElems, stream0[i]);
                }
            }

            // Notify stream0 that stream1 is complete and record the time of
            // the total transaction
            cudaEventRecord(stop[j], stream1[j]);
            cudaStreamWaitEvent(stream0[i], stop[j], 0);
            cudaEventRecord(stop[i], stream0[i]);

            // Release the queued operations
            *flag = 1;
            cudaStreamSynchronize(stream0[i]);
            cudaStreamSynchronize(stream1[j]);
            cudaCheckError();

            float time_ms;
            cudaEventElapsedTime(&time_ms, start[i], stop[i]);
            double time_s = time_ms / 1e3;

            double gb = 2.0 * numElems * sizeof(int) * repeat / (double)1e9;
            if (i == j) {
                gb *= 2;    //must count both the read and the write here
            }
            bandwidthMatrix[i * numGPUs + j] = gb / time_s;
            if (p2p && access) {
                cudaSetDevice(i);
                cudaDeviceDisablePeerAccess(j);
                cudaSetDevice(j);
                cudaDeviceDisablePeerAccess(i);
            }
        }
    }

    printf("   D\\D");

    for (int j = 0; j < numGPUs; j++) {
        printf("%6d ", j);
    }

    printf("\n");

    for (int i = 0; i < numGPUs; i++) {
        printf("%6d ", i);

        for (int j = 0; j < numGPUs; j++) {
            printf("%6.02f ", bandwidthMatrix[i * numGPUs + j]);
        }

        printf("\n");
    }

    for (int d = 0; d < numGPUs; d++) {
        cudaSetDevice(d);
        cudaFree(buffers[d]);
        cudaFree(buffersD2D[d]);
        cudaCheckError();
        cudaEventDestroy(start[d]);
        cudaCheckError();
        cudaEventDestroy(stop[d]);
        cudaCheckError();
        cudaStreamDestroy(stream0[d]);
        cudaCheckError();
        cudaStreamDestroy(stream1[d]);
        cudaCheckError();
    }

    cudaFreeHost((void *)flag);
    cudaCheckError();
}

void outputLatencyMatrix(int numGPUs, bool p2p, P2PDataTransfer p2p_method)
{
    int repeat = 100;
    volatile int *flag = NULL;
    StopWatchInterface *stopWatch = NULL;
    vector<int *> buffers(numGPUs);
    vector<int *> buffersD2D(numGPUs);  // buffer for D2D, that is, intra-GPU copy
    vector<cudaStream_t> stream(numGPUs);
    vector<cudaEvent_t> start(numGPUs);
    vector<cudaEvent_t> stop(numGPUs);

    cudaHostAlloc((void **)&flag, sizeof(*flag), cudaHostAllocPortable);
    cudaCheckError();

    if (!sdkCreateTimer(&stopWatch)) {
        printf("Failed to create stop watch\n");
        exit(EXIT_FAILURE);
    }
    sdkStartTimer(&stopWatch);

    for (int d = 0; d < numGPUs; d++) {
        cudaSetDevice(d);
        cudaStreamCreateWithFlags(&stream[d], cudaStreamNonBlocking);
        cudaMalloc(&buffers[d], 1);
        cudaMalloc(&buffersD2D[d], 1);
        cudaCheckError();
        cudaEventCreate(&start[d]);
        cudaCheckError();
        cudaEventCreate(&stop[d]);
        cudaCheckError();
    }

    vector<double> gpuLatencyMatrix(numGPUs * numGPUs);
    vector<double> cpuLatencyMatrix(numGPUs * numGPUs);

    for (int i = 0; i < numGPUs; i++) {
        cudaSetDevice(i);

        for (int j = 0; j < numGPUs; j++) {
            int access;
            if (p2p) {
                cudaDeviceCanAccessPeer(&access, i, j);
                if (access) {
                    cudaDeviceEnablePeerAccess(j, 0);
                    cudaCheckError();
                    cudaSetDevice(j);
                    cudaDeviceEnablePeerAccess(i, 0);
                    cudaSetDevice(i);
                    cudaCheckError();
                }
            }
            cudaStreamSynchronize(stream[i]);
            cudaCheckError();

            // Block the stream until all the work is queued up
            // DANGER! - cudaMemcpy*Async may infinitely block waiting for
            // room to push the operation, so keep the number of repeatitions
            // relatively low.  Higher repeatitions will cause the delay kernel
            // to timeout and lead to unstable results.
            *flag = 0;
            delay<<< 1, 1, 0, stream[i]>>>(flag);
            cudaCheckError();
            cudaEventRecord(start[i], stream[i]);

            sdkResetTimer(&stopWatch);
            if (i == j) {
                // Perform intra-GPU, D2D copies
                for (int r = 0; r < repeat; r++) {
                    cudaMemcpyPeerAsync(buffers[i], i, buffersD2D[i], i, 1, stream[i]);
                }
            }
            else {
                if (p2p_method == P2P_WRITE)
                {
                    for (int r = 0; r < repeat; r++) {
                        // Peform P2P writes
                        cudaMemcpyPeerAsync(buffers[j], j, buffers[i], i, 1, stream[i]);
                    }
                }
                else
                {
                    for (int r = 0; r < repeat; r++) {
                        // Peform P2P reads
                        cudaMemcpyPeerAsync(buffers[i], i, buffers[j], j, 1, stream[i]);
                    }
                }
            }
            float cpu_time_ms = sdkGetTimerValue(&stopWatch);

            cudaEventRecord(stop[i], stream[i]);
            // Now that the work has been queued up, release the stream
            *flag = 1;
            cudaStreamSynchronize(stream[i]);
            cudaCheckError();

            float gpu_time_ms;
            cudaEventElapsedTime(&gpu_time_ms, start[i], stop[i]);

            gpuLatencyMatrix[i * numGPUs + j] = gpu_time_ms * 1e3 / repeat;
            cpuLatencyMatrix[i * numGPUs + j] = cpu_time_ms * 1e3 / repeat;
            if (p2p && access) {
                cudaDeviceDisablePeerAccess(j);
                cudaSetDevice(j);
                cudaDeviceDisablePeerAccess(i);
                cudaSetDevice(i);
                cudaCheckError();
            }
        }
    }

    printf("   GPU");

    for (int j = 0; j < numGPUs; j++) {
        printf("%6d ", j);
    }

    printf("\n");

    for (int i = 0; i < numGPUs; i++) {
        printf("%6d ", i);

        for (int j = 0; j < numGPUs; j++) {
            printf("%6.02f ", gpuLatencyMatrix[i * numGPUs + j]);
        }

        printf("\n");
    }

    printf("\n   CPU");

    for (int j = 0; j < numGPUs; j++) {
        printf("%6d ", j);
    }

    printf("\n");

    for (int i = 0; i < numGPUs; i++) {
        printf("%6d ", i);

        for (int j = 0; j < numGPUs; j++) {
            printf("%6.02f ", cpuLatencyMatrix[i * numGPUs + j]);
        }

        printf("\n");
    }

    for (int d = 0; d < numGPUs; d++) {
        cudaSetDevice(d);
        cudaFree(buffers[d]);
        cudaFree(buffersD2D[d]);
        cudaCheckError();
        cudaEventDestroy(start[d]);
        cudaCheckError();
        cudaEventDestroy(stop[d]);
        cudaCheckError();
        cudaStreamDestroy(stream[d]);
        cudaCheckError();
    }

    sdkDeleteTimer(&stopWatch);

    cudaFreeHost((void *)flag);
    cudaCheckError();
}

int main(int argc, char **argv)
{
    int numGPUs;
    P2PDataTransfer p2p_method = P2P_WRITE;

    cudaGetDeviceCount(&numGPUs);
    cudaCheckError();

    //process command line args
    if (checkCmdLineFlag(argc, (const char**)argv, "help"))
    {
        printHelp();
        return 0;
    }

    if (checkCmdLineFlag(argc, (const char**)argv, "p2p_read"))
    {
        p2p_method = P2P_READ;
    }

    printf("[%s]\n", sSampleName);

    //output devices
    for (int i = 0; i < numGPUs; i++) {
        cudaDeviceProp prop;
        cudaGetDeviceProperties(&prop, i);
        cudaCheckError();
        printf("Device: %d, %s, pciBusID: %x, pciDeviceID: %x, pciDomainID:%x\n", i, prop.name, prop.pciBusID, prop.pciDeviceID, prop.pciDomainID);
    }

    checkP2Paccess(numGPUs);

    //Check peer-to-peer connectivity
    printf("P2P Connectivity Matrix\n");
    printf("     D\\D");

    for (int j = 0; j < numGPUs; j++) {
        printf("%6d", j);
    }
    printf("\n");

    for (int i = 0; i < numGPUs; i++) {
        printf("%6d\t", i);
        for (int j = 0; j < numGPUs; j++) {
            if (i != j) {
                int access;
                cudaDeviceCanAccessPeer(&access, i, j);
                cudaCheckError();
                printf("%6d", (access) ? 1 : 0);
            }
            else {
                printf("%6d", 1);
            }
        }
        printf("\n");
    }

    printf("Unidirectional P2P=Disabled Bandwidth Matrix (GB/s)\n");
    outputBandwidthMatrix(numGPUs, false, P2P_WRITE);
    printf("Unidirectional P2P=Enabled Bandwidth (P2P Writes) Matrix (GB/s)\n");
    outputBandwidthMatrix(numGPUs, true, P2P_WRITE);
    if (p2p_method == P2P_READ)
    {
        printf("Unidirectional P2P=Enabled Bandwidth (P2P Reads) Matrix (GB/s)\n");
        outputBandwidthMatrix(numGPUs, true, p2p_method);
    }
    printf("Bidirectional P2P=Disabled Bandwidth Matrix (GB/s)\n");
    outputBidirectionalBandwidthMatrix(numGPUs, false);
    printf("Bidirectional P2P=Enabled Bandwidth Matrix (GB/s)\n");
    outputBidirectionalBandwidthMatrix(numGPUs, true);

    printf("P2P=Disabled Latency Matrix (us)\n");
    outputLatencyMatrix(numGPUs, false, P2P_WRITE);
    printf("P2P=Enabled Latency (P2P Writes) Matrix (us)\n");
    outputLatencyMatrix(numGPUs, true, P2P_WRITE);
    if (p2p_method == P2P_READ)
    {
        printf("P2P=Enabled Latency (P2P Reads) Matrix (us)\n");
        outputLatencyMatrix(numGPUs, true, p2p_method);
    }

    printf("\nNOTE: The CUDA Samples are not meant for performance measurements. Results may vary when GPU Boost is enabled.\n");

    exit(EXIT_SUCCESS);
}
