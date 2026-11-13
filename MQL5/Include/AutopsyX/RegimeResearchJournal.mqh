//+------------------------------------------------------------------+
//|                                      RegimeResearchJournal.mqh   |
//|  Append-only, bar-level research journal for R1-R8 classifications|
//|  Analysis only. Persistence failure never changes trade execution. |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_REGIMERESEARCHJOURNAL_MQH
#define AX_REGIMERESEARCHJOURNAL_MQH

#include "Defs.mqh"
#include "RegimeClassifierEngine.mqh"
#include "RegimeIntelligenceEngine.mqh"
#include "VolatilityEngine.mqh"

#define AX_REGIME_JOURNAL_FIELDS 18

class CRegimeResearchJournal
  {
private:
   int               m_handle;
   string            m_fileName;
   string            m_symbol;
   ENUM_TIMEFRAMES   m_timeframe;
   datetime          m_lastTimestamp;
   bool              m_persistenceHealthy;
   bool              m_needsLineBreak;
   int               m_rowsWritten;

   string            SafeSymbol(const string symbol) const
     {
      string value=symbol;
      StringReplace(value,",","_");
      StringReplace(value,";","_");
      StringReplace(value," ","_");
      return(value);
     }

   bool              ValidateRow(const string line,datetime &timestampOut) const
     {
      timestampOut=0;
      string fields[];
      ushort separator=StringGetCharacter(",",0);
      int count=StringSplit(line,separator,fields);
      if(count!=AX_REGIME_JOURNAL_FIELDS) return(false);

      long stamp=StringToInteger(fields[0]);
      if(stamp<=0 || fields[1]!=m_symbol) return(false);
      if(StringToInteger(fields[2])!=(long)m_timeframe) return(false);

      long quality=StringToInteger(fields[3]);
      long regimeClass=StringToInteger(fields[4]);
      long age=StringToInteger(fields[6]);
      long transition=StringToInteger(fields[7]);
      long previousClass=StringToInteger(fields[8]);
      long baseRegime=StringToInteger(fields[9]);
      long volatilityState=StringToInteger(fields[10]);
      long macroAvailable=StringToInteger(fields[14]);

      double confidence=StringToDouble(fields[5]);
      double atr=StringToDouble(fields[11]);
      double percentile=StringToDouble(fields[12]);
      double acceleration=StringToDouble(fields[13]);
      double macroAgreement=StringToDouble(fields[15]);
      double slope=StringToDouble(fields[16]);
      double volRatio=StringToDouble(fields[17]);

      if((quality!=0 && quality!=1) || regimeClass<0 || regimeClass>8 ||
         age<0 || (transition!=0 && transition!=1) ||
         previousClass<0 || previousClass>8 || baseRegime<0 || baseRegime>8 ||
         volatilityState<0 || volatilityState>4 ||
         (macroAvailable!=0 && macroAvailable!=1))
         return(false);
      if(!MathIsValidNumber(confidence) || confidence<0.0 || confidence>100.0 ||
         !MathIsValidNumber(atr) || atr<0.0 ||
         !MathIsValidNumber(percentile) || percentile<0.0 || percentile>100.0 ||
         !MathIsValidNumber(acceleration) ||
         !MathIsValidNumber(macroAgreement) ||
         !MathIsValidNumber(slope) || !MathIsValidNumber(volRatio))
         return(false);

      timestampOut=(datetime)stamp;
      return(true);
     }

   bool              RecoverTail(void)
     {
      int reader=FileOpen(m_fileName,FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE);
      if(reader==INVALID_HANDLE) return(false);

      bool firstLine=true;
      bool lastNonEmptyValid=true;
      m_lastTimestamp=0;
      while(!FileIsEnding(reader))
        {
         string line=FileReadString(reader);
         if(firstLine)
           {
            firstLine=false;
            if(line!="timestamp,symbol,timeframe,data_quality,regime_class,confidence,age_bars,transition,previous_class,base_regime,volatility_state,atr,volatility_percentile,atr_acceleration_pct,macro_available,macro_agreement,slope,vol_ratio")
              {
               FileClose(reader);
               return(false);
              }
            continue;
           }
         if(StringLen(line)==0) continue;

         datetime rowTime=0;
         bool valid=ValidateRow(line,rowTime);
         lastNonEmptyValid=valid;
         if(valid && rowTime>m_lastTimestamp) m_lastTimestamp=rowTime;
        }
      FileClose(reader);
      m_needsLineBreak=!lastNonEmptyValid;
      return(!firstLine);
     }

   bool              WriteHeader(void)
     {
      string header="timestamp,symbol,timeframe,data_quality,regime_class,confidence,age_bars,transition,previous_class,base_regime,volatility_state,atr,volatility_percentile,atr_acceleration_pct,macro_available,macro_agreement,slope,vol_ratio\r\n";
      uint expected=(uint)StringLen(header);
      uint written=FileWriteString(m_handle,header);
      FileFlush(m_handle);
      return(written==expected && FileSize(m_handle)==written);
     }

public:
                     CRegimeResearchJournal(void)
     {
      m_handle=INVALID_HANDLE;
      m_fileName="";
      m_symbol="";
      m_timeframe=PERIOD_CURRENT;
      m_lastTimestamp=0;
      m_persistenceHealthy=false;
      m_needsLineBreak=false;
      m_rowsWritten=0;
     }

   bool              Init(const string symbol,const ENUM_TIMEFRAMES timeframe)
     {
      if(m_handle!=INVALID_HANDLE) FileClose(m_handle);
      m_handle=INVALID_HANDLE;
      m_symbol=symbol;
      m_timeframe=timeframe;
      m_lastTimestamp=0;
      m_rowsWritten=0;
      m_needsLineBreak=false;
      m_persistenceHealthy=false;

      if(StringLen(symbol)==0 || timeframe<=0) return(false);
      m_fileName=StringFormat("AX_RegimeResearch_%s_%d.csv",SafeSymbol(symbol),(int)timeframe);

      int createHandle=FileOpen(m_fileName,FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ);
      if(createHandle==INVALID_HANDLE) return(false);
      if(FileSize(createHandle)==0)
        {
         string header="timestamp,symbol,timeframe,data_quality,regime_class,confidence,age_bars,transition,previous_class,base_regime,volatility_state,atr,volatility_percentile,atr_acceleration_pct,macro_available,macro_agreement,slope,vol_ratio\r\n";
         uint expected=(uint)StringLen(header);
         uint written=FileWriteString(createHandle,header);
         FileFlush(createHandle);
         if(written!=expected || FileSize(createHandle)!=written)
           {
            FileClose(createHandle);
            return(false);
           }
        }
      FileClose(createHandle);

      if(!RecoverTail()) return(false);
      m_handle=FileOpen(m_fileName,FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ);
      if(m_handle==INVALID_HANDLE) return(false);
      FileSeek(m_handle,0,SEEK_END);
      m_persistenceHealthy=true;
      return(true);
     }

   bool              Record(const SAxRegimeClassification &classification,
                            const SAxRegimeIntelligence &intelligence,
                            const CRegimeEngine &baseRegime,
                            const CVolatilityEngine &volatility)
     {
      if(!m_persistenceHealthy || m_handle==INVALID_HANDLE) return(false);
      if(classification.timestamp<=0 || classification.timestamp<=m_lastTimestamp) return(false);

      string payload=StringFormat("%I64d,%s,%d,%d,%d,%.2f,%d,%d,%d,%d,%d,%.10f,%.2f,%.2f,%d,%.2f,%.8f,%.4f\r\n",
                                  (long)classification.timestamp,SafeSymbol(m_symbol),(int)m_timeframe,
                                  classification.dataQualityOk?1:0,(int)classification.regime,
                                  classification.regimeConfidence,classification.regimeAgeBars,
                                  classification.transitionDetected?1:0,
                                  classification.hasPreviousRegime?(int)classification.previousRegime:0,
                                  (int)baseRegime.Regime(),(int)volatility.State(),
                                  volatility.CurrentAtr(),volatility.PercentileRank(),
                                  volatility.AccelerationPct(),intelligence.macroDataAvailable?1:0,
                                  intelligence.macroAgreementScore,baseRegime.Slope(),baseRegime.VolRatio());
      if(m_needsLineBreak) payload="\r\n"+payload;

      FileSeek(m_handle,0,SEEK_END);
      ulong sizeBefore=FileSize(m_handle);
      uint expected=(uint)StringLen(payload);
      uint written=FileWriteString(m_handle,payload);
      FileFlush(m_handle);
      ulong sizeAfter=FileSize(m_handle);
      if(written!=expected || sizeAfter<=sizeBefore)
        {
         m_persistenceHealthy=false;
         PrintFormat("FLIPDEMON REGIME JOURNAL ERROR: append/flush verification failed for %s at %s. Journal latched unhealthy; trading decisions are unchanged.",
                     m_symbol,TimeToString(classification.timestamp,TIME_DATE|TIME_MINUTES));
         return(false);
        }

      m_lastTimestamp=classification.timestamp;
      m_needsLineBreak=false;
      m_rowsWritten++;
      return(true);
     }

   bool              IsPersisting(void) const
     {
      return(m_persistenceHealthy && m_handle!=INVALID_HANDLE);
     }

   datetime          LastTimestamp(void) const { return(m_lastTimestamp); }
   int               RowsWritten(void) const { return(m_rowsWritten); }

   void              Deinit(void)
     {
      if(m_handle!=INVALID_HANDLE)
        {
         FileFlush(m_handle);
         FileClose(m_handle);
         m_handle=INVALID_HANDLE;
        }
     }
  };

#endif // AX_REGIMERESEARCHJOURNAL_MQH
