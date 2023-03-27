#ifndef NPKIT_EVENT_H_
#define NPKIT_EVENT_H_

#define NPKIT_EVENT_INVALID 0x0

#define NPKIT_EVENT_TIME_SYNC_GPU 0x1
#define NPKIT_EVENT_TIME_SYNC_CPU 0x2

#define NPKIT_EVENT_SM_REDUCE_ENTRY 0x3
#define NPKIT_EVENT_SM_REDUCE_EXIT 0x4

#define NPKIT_EVENT_IB_SEND_ENTRY 0x5
#define NPKIT_EVENT_IB_SEND_EXIT 0x6
#define NPKIT_EVENT_IB_RECV_ENTRY 0x7
#define NPKIT_EVENT_IB_RECV_EXIT 0x8

#define NPKIT_EVENT_DMA_SEND_ENTRY 0x9
#define NPKIT_EVENT_DMA_SEND_EXIT 0xA
#define NPKIT_EVENT_DMA_RECV_ENTRY 0xB
#define NPKIT_EVENT_DMA_RECV_EXIT 0xC

#endif