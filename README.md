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
