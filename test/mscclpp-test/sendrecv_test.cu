#include <algorithm>
#include <cassert>
#include <cstdio>
#include <cstring>
#include <iostream>
#include <mscclpp/channel.hpp>
#include <mscclpp/concurrency.hpp>
#include <mscclpp/epoch.hpp>
#include <string>
#include <vector>

#include "common.hpp"

constexpr size_t BLOCK_THREADS_NUM = 1024;
// Try to use more blocks if per-block data size exceeds this threshold
constexpr size_t THRES_BYTES_PER_BLOCK = 8192;
// Let it no more than the number of SMs on a GPU
constexpr size_t MAX_BLOCKS_NUM = 32;

#define ALIGN 4

__constant__ mscclpp::channel::DirectChannel constDirChans[2];

inline int getBlockNum(size_t count) {
  return std::min((count + THRES_BYTES_PER_BLOCK - 1) / THRES_BYTES_PER_BLOCK, MAX_BLOCKS_NUM);
}

inline mscclpp::Transport getTransport(int rank, int peerRank, int nRanksPerNode, mscclpp::Transport ibDevice) {
  return rank / nRanksPerNode == peerRank / nRanksPerNode ? mscclpp::Transport::CudaIpc : ibDevice;
}

__device__ mscclpp::DeviceSyncer deviceSyncer;

__global__ void kernel(int rank, size_t dataSize, size_t dataPerBlock) {
  size_t startIndex = blockIdx.x * dataPerBlock;
  size_t blockDataSize = min(dataSize - startIndex, dataPerBlock);
  int globalIndex = blockIdx.x * blockDim.x + threadIdx.x;

  mscclpp::channel::DirectChannel sendConn = constDirChans[0];
  mscclpp::channel::DirectChannel recvConn = constDirChans[1];

  sendConn.put(startIndex, startIndex, blockDataSize, threadIdx.x, blockDim.x);
  deviceSyncer.sync(gridDim.x);
  if (globalIndex == 0) {
    sendConn.signal();
    recvConn.wait();
  }
}

class SendRecvTestColl : public BaseTestColl {
 public:
  SendRecvTestColl() = default;
  ~SendRecvTestColl() override = default;

  void runColl(const TestArgs& args, cudaStream_t stream) override;
  void initData(const TestArgs& args, std::vector<void*> sendBuff, void* expectedBuff) override;
  void getBw(const double deltaSec, double& algBw /*OUT*/, double& busBw /*OUT*/) override;
  void setupCollTest(size_t size) override;
};

void SendRecvTestColl::runColl(const TestArgs& args, cudaStream_t stream) {
  size_t sendBytes = sendCount_ * typeSize_;
  int blockNum = getBlockNum(sendBytes);
  size_t bytesPerBlock = (sendBytes + blockNum - 1) / blockNum;
  kernel<<<blockNum, BLOCK_THREADS_NUM, 0, stream>>>(args.rank, sendBytes, bytesPerBlock);
}

void SendRecvTestColl::getBw(const double deltaSec, double& algBw /*OUT*/, double& busBw /*OUT*/) {
  double baseBw = (double)(paramCount_ * typeSize_) / 1.0E9 / deltaSec;
  algBw = baseBw;
  double factor = 1;
  busBw = baseBw * factor;
}

void SendRecvTestColl::initData(const TestArgs& args, std::vector<void*> sendBuff, void* expectedBuff) {
  int rank = args.rank;
  assert(sendBuff.size() == 1);
  CUDATHROW(cudaMemset(sendBuff[0], 0, sendCount_ * typeSize_));

  // TODO: The type should not limited to int.
  std::vector<int> dataHost(std::max(sendCount_, recvCount_), rank);
  CUDATHROW(cudaMemcpy(sendBuff[0], dataHost.data(), sendCount_ * typeSize_, cudaMemcpyHostToDevice));

  int peerRank = (rank - 1 + args.totalRanks) % args.totalRanks;
  for (size_t i = 0; i < recvCount_; i++) {
    dataHost[i] = peerRank;
  }

  std::memcpy(expectedBuff, dataHost.data(), recvCount_ * typeSize_);
}

void SendRecvTestColl::setupCollTest(size_t size) {
  size_t count = size / typeSize_;
  size_t base = (count / ALIGN) * ALIGN;
  sendCount_ = base;
  recvCount_ = base;
  paramCount_ = base;
  expectedCount_ = base;

  mscclpp::DeviceSyncer syncer = {};
  CUDATHROW(cudaMemcpyToSymbol(deviceSyncer, &syncer, sizeof(mscclpp::DeviceSyncer)));
}

class SendRecvTestEngine : public BaseTestEngine {
 public:
  SendRecvTestEngine(const TestArgs& args);
  ~SendRecvTestEngine() override = default;

  void allocateBuffer() override;
  void setupConnections() override;

  std::vector<void*> getSendBuff() override;
  void* getRecvBuff() override;
  void* getScratchBuff() override;

 private:
  void* getExpectedBuff() override;

  std::vector<std::shared_ptr<int>> devicePtrs_;
  std::shared_ptr<int[]> expectedBuff_;
};

SendRecvTestEngine::SendRecvTestEngine(const TestArgs& args) : BaseTestEngine(args) { inPlace_ = false; }

void SendRecvTestEngine::allocateBuffer() {
  std::shared_ptr<int> sendBuff = mscclpp::allocSharedCuda<int>(args_.maxBytes / sizeof(int));
  std::shared_ptr<int> recvBuff = mscclpp::allocSharedCuda<int>(args_.maxBytes / sizeof(int));
  devicePtrs_.push_back(sendBuff);
  devicePtrs_.push_back(recvBuff);

  expectedBuff_ = std::shared_ptr<int[]>(new int[args_.maxBytes / sizeof(int)]);
}

void SendRecvTestEngine::setupConnections() {
  auto ibDevice = IBs[args_.localRank];
  int worldSize = args_.totalRanks;
  int sendToRank = (args_.rank + 1) % worldSize;
  int recvFromRank = (args_.rank - 1 + worldSize) % worldSize;
  std::array<int, 2> ranks = {sendToRank, recvFromRank};
  auto service = std::dynamic_pointer_cast<mscclpp::channel::DeviceChannelService>(chanService_);

  std::vector<std::shared_ptr<mscclpp::DirectEpoch>> directEpochs;

  auto sendConn =
      comm_->connectOnSetup(sendToRank, 0, getTransport(args_.rank, sendToRank, args_.nRanksPerNode, ibDevice));
  directEpochs.push_back(std::make_shared<mscclpp::DirectEpoch>(*comm_, sendConn));
  if (recvFromRank != sendToRank) {
    auto recvConn =
        comm_->connectOnSetup(recvFromRank, 0, getTransport(args_.rank, recvFromRank, args_.nRanksPerNode, ibDevice));
    directEpochs.push_back(std::make_shared<mscclpp::DirectEpoch>(*comm_, recvConn));
  } else {
    // reuse the send channel if worldSize is 2
    directEpochs.push_back(directEpochs[0]);
  }
  comm_->setup();

  std::vector<mscclpp::RegisteredMemory> localMemories;
  std::vector<mscclpp::NonblockingFuture<mscclpp::RegisteredMemory>> futureRemoteMemory;

  for (int i : {0, 1}) {
    auto regMem = comm_->registerMemory(devicePtrs_[i].get(), args_.maxBytes, mscclpp::Transport::CudaIpc | ibDevice);
    comm_->sendMemoryOnSetup(regMem, ranks[i], 0);
    localMemories.push_back(regMem);
    futureRemoteMemory.push_back(comm_->recvMemoryOnSetup(ranks[1 - i], 0));
    comm_->setup();
  }

  // swap to make sure devicePtrs_[0] in local rank write to devicePtrs_[1] in remote rank
  std::swap(futureRemoteMemory[0], futureRemoteMemory[1]);
  std::vector<mscclpp::channel::DirectChannel> dirChannels;
  for (int i : {0, 1}) {
    // We assume ranks in the same node
    dirChannels.emplace_back(directEpochs[i]->deviceHandle(), futureRemoteMemory[i].get(),
                             (void*)localMemories[i].data());
  }
  cudaMemcpyToSymbol(constDirChans, dirChannels.data(), sizeof(mscclpp::channel::DirectChannel) * dirChannels.size());
}

std::vector<void*> SendRecvTestEngine::getSendBuff() { return {devicePtrs_[0].get()}; }

void* SendRecvTestEngine::getExpectedBuff() { return expectedBuff_.get(); }

void* SendRecvTestEngine::getRecvBuff() { return devicePtrs_[1].get(); }

void* SendRecvTestEngine::getScratchBuff() { return nullptr; }

std::shared_ptr<BaseTestEngine> getTestEngine(const TestArgs& args) {
  return std::make_shared<SendRecvTestEngine>(args);
}

std::shared_ptr<BaseTestColl> getTestColl() { return std::make_shared<SendRecvTestColl>(); }