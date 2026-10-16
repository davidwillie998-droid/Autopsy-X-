//+------------------------------------------------------------------+
//| TickBuffer.mqh                                                    |
//| Fixed-capacity circular buffer of recent ticks. Rolling-window    |
//| storage only - no per-tick heap allocation, optimized for speed.  |
//+------------------------------------------------------------------+
#pragma once

struct AXTickSample
{
   datetime time;
   ulong    time_msc;
   double   bid;
   double   ask;
   double   mid;
};

class CAXTickBuffer
{
private:
   AXTickSample m_data[];
   int          m_capacity;
   int          m_head;      // index where next tick will be written
   int          m_count;     // number of valid samples (<= capacity)

public:
   CAXTickBuffer(void) : m_capacity(0), m_head(0), m_count(0) {}

   void Init(const int capacity)
   {
      m_capacity = MathMax(capacity, 8);
      ArrayResize(m_data, m_capacity);
      m_head  = 0;
      m_count = 0;
   }

   void Push(const datetime t, const ulong t_msc, const double bid, const double ask)
   {
      m_data[m_head].time     = t;
      m_data[m_head].time_msc = t_msc;
      m_data[m_head].bid      = bid;
      m_data[m_head].ask      = ask;
      m_data[m_head].mid      = (bid + ask) * 0.5;
      m_head = (m_head + 1) % m_capacity;
      if(m_count < m_capacity) m_count++;
   }

   int Count(void) const { return m_count; }
   int Capacity(void) const { return m_capacity; }

   // idx = 0 -> most recent sample, idx = 1 -> one before that, etc.
   bool Get(const int idx, AXTickSample &out) const
   {
      if(idx < 0 || idx >= m_count) return false;
      int pos = m_head - 1 - idx;
      while(pos < 0) pos += m_capacity;
      out = m_data[pos];
      return true;
   }
};
