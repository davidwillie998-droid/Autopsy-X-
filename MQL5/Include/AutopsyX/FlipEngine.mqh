//+------------------------------------------------------------------+
//|                                                   FlipEngine.mqh |
//|  Flipdemon Reversal Engine (spec section 5)                      |
//|  Requires multi-signal confirmation before reversing direction.   |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_FLIPENGINE_MQH
#define AX_FLIPENGINE_MQH
#include "Defs.mqh"
#include "Momentum.mqh"
#include "Microstructure.mqh"

class CFlipEngine
  {
private:
   int               m_requiredConfirmations;
   double            m_minFlipConfidence;
   int               m_confirmCount;
   ENUM_AX_DIR       m_pendingDir;
   int               m_flipGeneration;

public:
                     CFlipEngine(void)
     {
      m_requiredConfirmations = 3;
      m_minFlipConfidence     = 70.0;
      m_confirmCount = 0;
      m_pendingDir   = AX_DIR_NONE;
      m_flipGeneration = 0;
     }

   void              Configure(const int requiredConfirmations,const double minFlipConfidence)
     {
      m_requiredConfirmations = MathMax(1,requiredConfirmations);
      m_minFlipConfidence     = minFlipConfidence;
     }

   void              Reset(void)
     {
      m_confirmCount = 0;
      m_pendingDir   = AX_DIR_NONE;
     }

   //--- evaluate one tick's worth of evidence against the currently held direction ---
   //--- returns true exactly once the flip is fully confirmed ---
   bool              Evaluate(const ENUM_AX_DIR heldDir,const SAxScore &score,
                               const CMomentumEngine &mom,const CMicrostructureEngine &micro,
                               const bool spreadOk)
     {
      if(heldDir==AX_DIR_NONE) { Reset(); return(false); }

      ENUM_AX_DIR opposite = (heldDir==AX_DIR_BUY) ? AX_DIR_SELL : AX_DIR_BUY;

      bool opposingMomentum   = (opposite==AX_DIR_BUY) ? mom.PersistentBull() : mom.PersistentBear();
      bool opposingAccel      = (opposite==AX_DIR_BUY) ? (mom.Acceleration()>0) : (mom.Acceleration()<0);
      bool opposingDisplace   = (opposite==AX_DIR_BUY) ? (mom.DisplacementPts()>0) : (mom.DisplacementPts()<0);
      bool opposingMicroShift = (opposite==AX_DIR_BUY) ? (micro.TickImbalance()>0.1) : (micro.TickImbalance()<-0.1);
      bool opposingScore      = (score.action==opposite);
      bool sufficientConf     = (score.confidence>=m_minFlipConfidence);

      int factorsMet = 0;
      if(opposingMomentum)   factorsMet++;
      if(opposingAccel)      factorsMet++;
      if(opposingDisplace)   factorsMet++;
      if(opposingMicroShift) factorsMet++;
      if(spreadOk)           factorsMet++;

      //--- a valid confirmation tick requires the score engine itself to agree,
      //--- sufficient confidence, an acceptable spread, and at least 3 of the
      //--- remaining microstructure/momentum factors (spec section 5) ---
      bool tickConfirms = opposingScore && sufficientConf && spreadOk && (factorsMet>=4);

      if(tickConfirms && opposite==m_pendingDir)
        {
         m_confirmCount++;
        }
      else if(tickConfirms)
        {
         m_pendingDir   = opposite;
         m_confirmCount = 1;
        }
      else
        {
         m_confirmCount = 0;
         m_pendingDir   = AX_DIR_NONE;
        }

      if(m_confirmCount>=m_requiredConfirmations)
        {
         m_flipGeneration++;
         Reset();
         return(true);
        }
      return(false);
     }

   int               PendingConfirmations(void) const { return(m_confirmCount); }
   int               RequiredConfirmations(void) const { return(m_requiredConfirmations); }
   int               FlipGeneration(void) const { return(m_flipGeneration); }
  };
//+------------------------------------------------------------------+
#endif // AX_FLIPENGINE_MQH
