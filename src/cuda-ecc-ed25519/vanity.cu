#include <vector>
#include <random>
#include <chrono>
#include <string.h>

#include <iostream>
#include <ctime>

#include <assert.h>
#include <inttypes.h>
#include <pthread.h>
#include <stdio.h>

#include "curand_kernel.h"
#include "ed25519.h"
#include "fixedint.h"
#include "gpu_common.h"
#include "gpu_ctx.h"

#include "keypair.cu"
#include "sc.cu"
#include "fe.cu"
#include "ge.cu"
#include "sha512.cu"
#include "../config.h"

/* -- Types ----------------------------------------------------------------- */

typedef struct {
	// CUDA Random States.
	curandState*    states[8];
} config;

/* -- Prototypes, Because C++ ----------------------------------------------- */

void            vanity_setup(config& vanity);
void            vanity_run(config& vanity);
void __global__ vanity_init(unsigned long long int* seed, curandState* state);
void __global__ vanity_scan(curandState* state, int* keys_found, int* gpu, int* execution_count);
bool __device__ b58enc(char* b58, size_t* b58sz, uint8_t* data, size_t binsz);

/* -- Entry Point ----------------------------------------------------------- */

void print_usage() {
    printf("Usage: vanity [options] prefix1 [prefix2 ...]\n");
    printf("Options:\n");
	printf("  --suffix               Match patterns at the end of keys instead of beginning\n");
    printf("  -n, --num-keys NUM     Number of keys to generate before stopping (default: 100)\n");    
    printf("  -i, --iterations NUM   Maximum number of iterations (default: 100000)\n");
    printf("  -a, --attempts NUM     Attempts per execution (default: 100000)\n");
    printf("  prefix1, prefix2, etc: Patterns to search for. Use ? as wildcard.\n");
    printf("Example: vanity -n 5 --suffix -i 50000 -a 200000 ABC?? DEF??\n");
}


int main(int argc, char const* argv[]) {
    ed25519_set_verbose(true);

    if (argc < 2) {
        print_usage();
        return 1;
    }

    // Default values

    bool use_suffix = false;
    
    // Parse arguments
    int arg_idx = 1;
    
    // Process optional flags first
    while (arg_idx < argc) {
        if (strcmp(argv[arg_idx], "-n") == 0 || strcmp(argv[arg_idx], "--num-keys") == 0) {
            if (arg_idx + 1 >= argc) {
                printf("Error: -n/--num-keys requires a number\n");
                print_usage();
                return 1;
            }
            STOP_AFTER_KEYS_FOUND = atoi(argv[arg_idx + 1]);
            arg_idx += 2;
        }
        else if (strcmp(argv[arg_idx], "-i") == 0 || strcmp(argv[arg_idx], "--iterations") == 0) {
            if (arg_idx + 1 >= argc) {
                printf("Error: -i/--iterations requires a number\n");
                print_usage();
                return 1;
            }
            MAX_ITERATIONS = atoi(argv[arg_idx + 1]);
            arg_idx += 2;
        }
        else if (strcmp(argv[arg_idx], "-a") == 0 || strcmp(argv[arg_idx], "--attempts") == 0) {
            if (arg_idx + 1 >= argc) {
                printf("Error: -a/--attempts requires a number\n");
                print_usage();
                return 1;
            }
            attempts_per_exec = atoi(argv[arg_idx + 1]);
            arg_idx += 2;
        }
        else if (strcmp(argv[arg_idx], "--suffix") == 0) {
            use_suffix = true;
            arg_idx++;
        }
        else {
            // Not a flag, must be start of patterns
            break;
        }
    }

    // Parse patterns
    int prefix_count = 0;
    char host_prefixes[MAX_PATTERNS][32] = {0}; // Temporary array on host
    
    // Collect remaining arguments as patterns
    while (arg_idx < argc && prefix_count < MAX_PATTERNS) {
        if (strlen(argv[arg_idx]) >= 32) {
            printf("Error: Pattern too long: %s\n", argv[arg_idx]);
            return 1;
        }
        strcpy(host_prefixes[prefix_count], argv[arg_idx]);
        prefix_count++;
        arg_idx++;
    }

    if (prefix_count == 0) {
        printf("Error: At least one pattern is required\n");
        return 1;
    }

    if (arg_idx < argc) {
        printf("Warning: Maximum number of patterns (%d) exceeded, additional patterns ignored\n", MAX_PATTERNS);
    }

    // Copy patterns to device
    cudaMemcpyToSymbol(prefixes, host_prefixes, sizeof(host_prefixes));
    
    // Copy the suffix flag to device
    cudaMemcpyToSymbol(is_suffix_match, &use_suffix, sizeof(bool));
    
    // Copy other parameters to device constants
    cudaMemcpyToSymbol(ATTEMPTS_PER_EXECUTION, &attempts_per_exec, sizeof(int));

    printf("Configuration:\n");
    printf("  Max iterations: %d\n", MAX_ITERATIONS);
    printf("  Keys to find: %d\n", STOP_AFTER_KEYS_FOUND);
    printf("  Attempts per execution: %d\n", attempts_per_exec);
    printf("  Match type: %s\n", use_suffix ? "suffix" : "prefix");
    printf("Patterns to match:\n");
    for (int i = 0; i < prefix_count; i++) {
        printf("  Pattern %d: %s\n", i + 1, host_prefixes[i]);
    }

    // Pass the values to vanity_run
    config vanity;
    vanity_setup(vanity);
    vanity_run(vanity);

    return 0;
}

// SMITH
std::string getTimeStr(){
    std::time_t now = std::chrono::system_clock::to_time_t(std::chrono::system_clock::now());
    std::string s(30, '\0');
    std::strftime(&s[0], s.size(), "%Y-%m-%d %H:%M:%S", std::localtime(&now));
    return s;
}

// SMITH - safe? who knows
unsigned long long int makeSeed() {
    unsigned long long int seed = 0;
    char *pseed = (char *)&seed;

    std::random_device rd;

    for(unsigned int b=0; b<sizeof(seed); b++) {
      auto r = rd();
      char *entropy = (char *)&r;
      pseed[b] = entropy[0];
    }

    return seed;
}

/* -- Vanity Step Functions ------------------------------------------------- */

void vanity_setup(config &vanity) {
    printf("GPU: Initializing Memory\n");
    int gpuCount = 0;
    cudaError_t err = cudaGetDeviceCount(&gpuCount);
    if (err != cudaSuccess) {
        printf("Error: Failed to get GPU count: %s\n", cudaGetErrorString(err));
        exit(1);
    }
    if (gpuCount == 0) {
        printf("Error: No CUDA-capable devices found\n");
        exit(1);
    }

    printf("Found %d CUDA-capable device(s)\n", gpuCount);

    for (int i = 0; i < gpuCount; ++i) {
        cudaSetDevice(i);

        cudaDeviceProp device;
        err = cudaGetDeviceProperties(&device, i);
        if (err != cudaSuccess) {
            printf("Error: Failed to get device properties: %s\n", cudaGetErrorString(err));
            exit(1);
        }

        int blockSize = 0, minGridSize = 0, maxActiveBlocks = 0;
        cudaOccupancyMaxPotentialBlockSize(&minGridSize, &blockSize, vanity_scan, 0, 0);
        cudaOccupancyMaxActiveBlocksPerMultiprocessor(&maxActiveBlocks, vanity_scan, blockSize, 0);

        printf("GPU: %d (%s <%d, %d, %d>) -- W: %d, P: %d, TPB: %d, MTD: (%dx, %dy, %dz), MGS: (%dx, %dy, %dz)\n",
            i, device.name, blockSize, minGridSize, maxActiveBlocks,
            device.warpSize, device.multiProcessorCount, device.maxThreadsPerBlock,
            device.maxThreadsDim[0], device.maxThreadsDim[1], device.maxThreadsDim[2],
            device.maxGridSize[0], device.maxGridSize[1], device.maxGridSize[2]
        );

        unsigned long long int rseed = makeSeed();
        printf("Initialising from entropy: %llu\n", rseed);

        unsigned long long int* dev_rseed;
        err = cudaMalloc((void**)&dev_rseed, sizeof(unsigned long long int));
        if (err != cudaSuccess) {
            printf("Error: Failed to allocate device memory for rseed: %s\n", cudaGetErrorString(err));
            exit(1);
        }

        err = cudaMemcpy(dev_rseed, &rseed, sizeof(unsigned long long int), cudaMemcpyHostToDevice);
        if (err != cudaSuccess) {
            printf("Error: Failed to copy rseed to device: %s\n", cudaGetErrorString(err));
            exit(1);
        }

        err = cudaMalloc((void **)&(vanity.states[i]), maxActiveBlocks * blockSize * sizeof(curandState));
        if (err != cudaSuccess) {
            printf("Error: Failed to allocate device memory for states: %s\n", cudaGetErrorString(err));
            exit(1);
        }

        vanity_init<<<maxActiveBlocks, blockSize>>>(dev_rseed, vanity.states[i]);
        err = cudaGetLastError();
        if (err != cudaSuccess) {
            printf("Error: Failed to launch vanity_init kernel: %s\n", cudaGetErrorString(err));
            exit(1);
        }
    }

    printf("END: Initializing Memory\n");
}

void vanity_run(config &vanity) {
    int gpuCount = 0;
    cudaError_t err = cudaGetDeviceCount(&gpuCount);
    if (err != cudaSuccess) {
        printf("Error: Failed to get GPU count: %s\n", cudaGetErrorString(err));
        exit(1);
    }

    unsigned long long int executions_total = 0;
    unsigned long long int executions_this_iteration;
    int executions_this_gpu;
    int* dev_executions_this_gpu[100];

    int keys_found_total = 0;
    int keys_found_this_iteration;
    int* dev_keys_found[100];

    for (int i = 0; i < MAX_ITERATIONS; ++i) {
        auto start = std::chrono::high_resolution_clock::now();
        executions_this_iteration = 0;

        for (int g = 0; g < gpuCount; ++g) {
            err = cudaSetDevice(g);
            if (err != cudaSuccess) {
                printf("Error: Failed to set device %d: %s\n", g, cudaGetErrorString(err));
                exit(1);
            }

            int blockSize = 0, minGridSize = 0, maxActiveBlocks = 0;
            cudaOccupancyMaxPotentialBlockSize(&minGridSize, &blockSize, vanity_scan, 0, 0);
            cudaOccupancyMaxActiveBlocksPerMultiprocessor(&maxActiveBlocks, vanity_scan, blockSize, 0);

            int* dev_g;
            err = cudaMalloc((void**)&dev_g, sizeof(int));
            if (err != cudaSuccess) {
                printf("Error: Failed to allocate device memory for dev_g: %s\n", cudaGetErrorString(err));
                exit(1);
            }

            err = cudaMemcpy(dev_g, &g, sizeof(int), cudaMemcpyHostToDevice);
            if (err != cudaSuccess) {
                printf("Error: Failed to copy g to device: %s\n", cudaGetErrorString(err));
                exit(1);
            }

            err = cudaMalloc((void**)&dev_keys_found[g], sizeof(int));
            if (err != cudaSuccess) {
                printf("Error: Failed to allocate device memory for dev_keys_found: %s\n", cudaGetErrorString(err));
                exit(1);
            }

            err = cudaMalloc((void**)&dev_executions_this_gpu[g], sizeof(int));
            if (err != cudaSuccess) {
                printf("Error: Failed to allocate device memory for dev_executions_this_gpu: %s\n", cudaGetErrorString(err));
                exit(1);
            }

            vanity_scan<<<maxActiveBlocks, blockSize>>>(vanity.states[g], dev_keys_found[g], dev_g, dev_executions_this_gpu[g]);
            err = cudaGetLastError();
            if (err != cudaSuccess) {
                printf("Error: Failed to launch vanity_scan kernel: %s\n", cudaGetErrorString(err));
                exit(1);
            }
        }

        err = cudaDeviceSynchronize();
        if (err != cudaSuccess) {
            printf("Error: Failed to synchronize devices: %s\n", cudaGetErrorString(err));
            exit(1);
        }

        auto finish = std::chrono::high_resolution_clock::now();

        for (int g = 0; g < gpuCount; ++g) {
            err = cudaMemcpy(&keys_found_this_iteration, dev_keys_found[g], sizeof(int), cudaMemcpyDeviceToHost);
            if (err != cudaSuccess) {
                printf("Error: Failed to copy keys_found from device: %s\n", cudaGetErrorString(err));
                exit(1);
            }
            keys_found_total += keys_found_this_iteration;

            err = cudaMemcpy(&executions_this_gpu, dev_executions_this_gpu[g], sizeof(int), cudaMemcpyDeviceToHost);
            if (err != cudaSuccess) {
                printf("Error: Failed to copy executions from device: %s\n", cudaGetErrorString(err));
                exit(1);
            }
            executions_this_iteration += executions_this_gpu * attempts_per_exec;
            executions_total += executions_this_gpu * attempts_per_exec;
        }

        // Print out performance Summary
        std::chrono::duration<double> elapsed = finish - start;
        printf("%s Iteration %d Attempts: %llu in %f at %fcps - Total Attempts %llu - keys found %d\n",
            getTimeStr().c_str(),
            i+1,
            executions_this_iteration, //(8 * 8 * 256 * 100000),
            elapsed.count(),
            executions_this_iteration / elapsed.count(),
            executions_total,
            keys_found_total
        );

        if ( keys_found_total >= STOP_AFTER_KEYS_FOUND ) {
            printf("Enough keys found, Done! \n");
            exit(0);	
        }	
    }

    printf("Iterations complete, Done!\n");
}

/* -- CUDA Vanity Functions ------------------------------------------------- */

void __global__ vanity_init(unsigned long long int* rseed, curandState* state) {
	int id = threadIdx.x + (blockIdx.x * blockDim.x);  
	curand_init(*rseed + id, id, 0, &state[id]);
}

void __global__ vanity_scan(curandState* state, int* keys_found, int* gpu, int* exec_count) {
	int id = threadIdx.x + (blockIdx.x * blockDim.x);
	const char hex[] = "0123456789abcdef";

	atomicAdd(exec_count, 1);

	// SMITH - should really be passed in, but hey ho
    	int prefix_letter_counts[MAX_PATTERNS];
    	for (unsigned int n = 0; n < sizeof(prefixes) / sizeof(prefixes[0]); ++n) {
        	if ( MAX_PATTERNS == n ) {
            		printf("NEVER SPEAK TO ME OR MY SON AGAIN");
            		return;
        	}
        	int letter_count = 0;
        	for(; prefixes[n][letter_count]!=0; letter_count++);
        	prefix_letter_counts[n] = letter_count;
    	}

	// Local Kernel State
	ge_p3 A;
	curandState localState     = state[id];
	unsigned char seed[32]     = {0};
	unsigned char publick[32]  = {0};
	unsigned char privatek[64] = {0};
	char key[256]              = {0};
	//char pkey[256]             = {0};

	// Start from an Initial Random Seed (Slow)
	// NOTE: Insecure random number generator, do not use keys generator by
	// this program in live.
	// SMITH: localState should be entropy random now
	for (int i = 0; i < 32; ++i) {
		float random    = curand_uniform(&localState);
		uint8_t keybyte = (uint8_t)(random * 255);
		seed[i]         = keybyte;
	}

	// Generate Random Key Data
	sha512_context md;

	// I've unrolled all the MD5 calls and special cased them to 32 byte
	// inputs, which eliminates a lot of branching. This is a pretty poor
	// way to optimize GPU code though.
	//
	// A better approach would be to split this application into two
	// different kernels, one that is warp-efficient for SHA512 generation,
	// and another that is warp efficient for bignum division to more
	// efficiently scan for prefixes. Right now bs58enc cuts performance
	// from 16M keys on my machine per second to 4M.
	for (int attempts = 0; attempts < ATTEMPTS_PER_EXECUTION; ++attempts) {
		// sha512_init Inlined
		md.curlen   = 0;
		md.length   = 0;
		md.state[0] = UINT64_C(0x6a09e667f3bcc908);
		md.state[1] = UINT64_C(0xbb67ae8584caa73b);
		md.state[2] = UINT64_C(0x3c6ef372fe94f82b);
		md.state[3] = UINT64_C(0xa54ff53a5f1d36f1);
		md.state[4] = UINT64_C(0x510e527fade682d1);
		md.state[5] = UINT64_C(0x9b05688c2b3e6c1f);
		md.state[6] = UINT64_C(0x1f83d9abfb41bd6b);
		md.state[7] = UINT64_C(0x5be0cd19137e2179);

		// sha512_update inlined
		// 
		// All `if` statements from this function are eliminated if we
		// will only ever hash a 32 byte seed input. So inlining this
		// has a drastic speed improvement on GPUs.
		//
		// This means:
		//   * Normally we iterate for each 128 bytes of input, but we are always < 128. So no iteration.
		//   * We can eliminate a MIN(inlen, (128 - md.curlen)) comparison, specialize to 32, branch prediction improvement.
		//   * We can eliminate the in/inlen tracking as we will never subtract while under 128
		//   * As a result, the only thing update does is copy the bytes into the buffer.
		const unsigned char *in = seed;
		for (size_t i = 0; i < 32; i++) {
			md.buf[i + md.curlen] = in[i];
		}
		md.curlen += 32;


		// sha512_final inlined
		// 
		// As update was effectively elimiated, the only time we do
		// sha512_compress now is in the finalize function. We can also
		// optimize this:
		//
		// This means:
		//   * We don't need to care about the curlen > 112 check. Eliminating a branch.
		//   * We only need to run one round of sha512_compress, so we can inline it entirely as we don't need to unroll.
		md.length += md.curlen * UINT64_C(8);
		md.buf[md.curlen++] = (unsigned char)0x80;

		while (md.curlen < 120) {
			md.buf[md.curlen++] = (unsigned char)0;
		}

		STORE64H(md.length, md.buf+120);

		// Inline sha512_compress
		uint64_t S[8], W[80], t0, t1;
		int i;

		/* Copy state into S */
		for (i = 0; i < 8; i++) {
			S[i] = md.state[i];
		}

		/* Copy the state into 1024-bits into W[0..15] */
		for (i = 0; i < 16; i++) {
			LOAD64H(W[i], md.buf + (8*i));
		}

		/* Fill W[16..79] */
		for (i = 16; i < 80; i++) {
			W[i] = Gamma1(W[i - 2]) + W[i - 7] + Gamma0(W[i - 15]) + W[i - 16];
		}

		/* Compress */
		#define RND(a,b,c,d,e,f,g,h,i) \
		t0 = h + Sigma1(e) + Ch(e, f, g) + K[i] + W[i]; \
		t1 = Sigma0(a) + Maj(a, b, c);\
		d += t0; \
		h  = t0 + t1;

		for (i = 0; i < 80; i += 8) {
			RND(S[0],S[1],S[2],S[3],S[4],S[5],S[6],S[7],i+0);
			RND(S[7],S[0],S[1],S[2],S[3],S[4],S[5],S[6],i+1);
			RND(S[6],S[7],S[0],S[1],S[2],S[3],S[4],S[5],i+2);
			RND(S[5],S[6],S[7],S[0],S[1],S[2],S[3],S[4],i+3);
			RND(S[4],S[5],S[6],S[7],S[0],S[1],S[2],S[3],i+4);
			RND(S[3],S[4],S[5],S[6],S[7],S[0],S[1],S[2],i+5);
			RND(S[2],S[3],S[4],S[5],S[6],S[7],S[0],S[1],i+6);
			RND(S[1],S[2],S[3],S[4],S[5],S[6],S[7],S[0],i+7);
		}

		#undef RND

		/* Feedback */
		for (i = 0; i < 8; i++) {
			md.state[i] = md.state[i] + S[i];
		}

		// We can now output our finalized bytes into the output buffer.
		for (i = 0; i < 8; i++) {
			STORE64H(md.state[i], privatek+(8*i));
		}

		// Code Until here runs at 87_000_000H/s.

		// ed25519 Hash Clamping
		privatek[0]  &= 248;
		privatek[31] &= 63;
		privatek[31] |= 64;

		// ed25519 curve multiplication to extract a public key.
		ge_scalarmult_base(&A, privatek);
		ge_p3_tobytes(publick, &A);

		// Code Until here runs at 87_000_000H/s still!

		size_t keysize = 256;
		b58enc(key, &keysize, publick, 32);

		// Code Until here runs at 22_000_000H/s. b58enc badly needs optimization.

		// We don't have access to strncmp/strlen here, I don't know
		// what the efficient way of doing this on a GPU is, so I'll
		// start with a dumb loop. There seem to be implementations out
		// there of bignunm division done in parallel as a CUDA kernel
		// so it might make sense to write a new parallel kernel to do
		// this.

                for (int i = 0; i < sizeof(prefixes) / sizeof(prefixes[0]); ++i) {
                    if (is_suffix_match) {
                        // For suffix matching, compare from the end
                        int key_len = 0;
                        while (key[key_len] != '\0') key_len++;
                        
                        for (int j = 0; j < prefix_letter_counts[i]; ++j) {
                            int key_pos = key_len - prefix_letter_counts[i] + j;
                            if (key_pos < 0) break;  // Pattern longer than key
                            
                            // it doesn't match this suffix, no need to continue
                            if (!(prefixes[i][j] == '?') && !(prefixes[i][j] == key[key_pos])) {
                                break;
                            }

                            // we got to the end of the suffix pattern, it matched!
                            if (j == (prefix_letter_counts[i] - 1)) {
                                atomicAdd(keys_found, 1);
                                
                                // Build the seed hex string
                                char seed_hex[65] = {0};
                                for(int n = 0; n < sizeof(seed); n++) {
                                    seed_hex[n*2] = hex[(seed[n] >> 4) & 0xF];
                                    seed_hex[n*2+1] = hex[seed[n] & 0xF];
                                }
                                
                                printf("MATCH:%s,%s\n", key, seed_hex);
                                break;
                            }
                        }
                    } else {
                        // Original prefix matching code
                        for (int j = 0; j < prefix_letter_counts[i]; ++j) {
                            if (!(prefixes[i][j] == '?') && !(prefixes[i][j] == key[j])) {
                                break;
                            }
                            if (j == (prefix_letter_counts[i] - 1)) {
                                atomicAdd(keys_found, 1);
                                
                                // Build the seed hex string
                                char seed_hex[65] = {0};
                                for(int n = 0; n < sizeof(seed); n++) {
                                    seed_hex[n*2] = hex[(seed[n] >> 4) & 0xF];
                                    seed_hex[n*2+1] = hex[seed[n] & 0xF];
                                }
                                
                                printf("MATCH:%s,%s\n", key, seed_hex);
                                break;
                            }
                        }
                    }
                }

		// Code Until here runs at 22_000_000H/s. So the above is fast enough.

		// Increment Seed.
		// NOTE: This is horrifically insecure. Please don't use these
		// keys on live. This increment is just so we don't have to
		// invoke the CUDA random number generator for each hash to
		// boost performance a little. Easy key generation, awful
		// security.
		for (int i = 0; i < 32; ++i) {
			if (seed[i] == 255) {
				seed[i]  = 0;
			} else {
				seed[i] += 1;
				break;
			}
		}
	}

	// Copy Random State so that future calls of this kernel/thread/block
	// don't repeat their sequences.
	state[id] = localState;
}

bool __device__ b58enc(
	char    *b58,
       	size_t  *b58sz,
       	uint8_t *data,
       	size_t  binsz
) {
	// Base58 Lookup Table
	const char b58digits_ordered[] = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

	const uint8_t *bin = data;
	int carry;
	size_t i, j, high, zcount = 0;
	size_t size;
	
	while (zcount < binsz && !bin[zcount])
		++zcount;
	
	size = (binsz - zcount) * 138 / 100 + 1;
	uint8_t buf[256];
	memset(buf, 0, size);
	
	for (i = zcount, high = size - 1; i < binsz; ++i, high = j)
	{
		for (carry = bin[i], j = size - 1; (j > high) || carry; --j)
		{
			carry += 256 * buf[j];
			buf[j] = carry % 58;
			carry /= 58;
			if (!j) {
				// Otherwise j wraps to maxint which is > high
				break;
			}
		}
	}
	
	for (j = 0; j < size && !buf[j]; ++j);
	
	if (*b58sz <= zcount + size - j) {
		*b58sz = zcount + size - j + 1;
		return false;
	}
	
	if (zcount) memset(b58, '1', zcount);
	for (i = zcount; j < size; ++i, ++j) b58[i] = b58digits_ordered[buf[j]];

	b58[i] = '\0';
	*b58sz = i + 1;
	
	return true;
}
