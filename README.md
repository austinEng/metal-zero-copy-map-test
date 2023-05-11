# Metal Zero Copy Mapping Test

This is a simple test which draws a large number of triangles using Metal.
The triangle data is stored in shared memory between two processes, and every
frame, the child process updates the color data.
There is no synchronization whatsoever.

The parent process can run in two modes:
 - Zero-copy import of the shared memory to render from it directly on the GPU.
 - One-copy import of the shared memory by `memcpy` from it to a MTLBuffer.

Every 1000 frames, it prints the average frame latency.

## Running the app
`./build.sh && ./bin/app numtriangles [copy]`

`./bin/app 100` will render 100 triangles using the 0-copy approach.
`./bin/app 1000 copy` will render 1000 triangles using the 1-copy approach.

## Test Results
The slowdown incurred from the copy comes out unsurprisingly to be the amount of time the `memcpy` itself takes. At 1 million triangles, this test app copies 32 Mb of data.

### Apple M1 Max
|100k triangles | |
|- |-|
| 0-copy | 1120 µs |
| 1-copy | 1375 µs (22.7% slower) |

|1M triangles| |
|-|-|
| 0-copy | 5840 µs |
| 1-copy | 7900 µs (35.2% slower) |

## Shared Memory Mapping Details
Below is an overview of how the app shares and maps the memory.

The child process creates a shared memory region "mem_port" using `mach_make_memory_entry_64`.

The child process allocates a "heap" using `vm_allocate`.

The child process maps "mem_port" to an arbitrary "mapped_address" using `vm_map`.

The child process remaps "mapped_address" into the middle of the "heap" using `vm_remap`.

The child process continually updates the triangle data stored in the middle of "heap".

The parent process receives "mem_port" from the child, maps it to an arbitrary "buf_address".

The parent process creates a MTLBuffer wrapping "buf_address" and renders from it as a vertex buffer.