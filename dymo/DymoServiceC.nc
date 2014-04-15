/*
 * Copyright (c) 2007 Romain Thouvenin <romain.thouvenin@gmail.com>
 * Published under the terms of the GNU General Public License (GPLv2).
 */

//#include "StorageVolumes.h" // Modified by Antonio Rosa. Now we save/read num_seq to/from internal EEPROM

/**
 * DymoServiceC - Implements the DYMO routing protocol
 *
 * @author Romain Thouvenin
 */

configuration DymoServiceC {
  provides {
    interface SplitControl;
  }
  uses {
    interface Packet;
    interface AMPacket;
    interface AMSend;
    interface Receive;
    interface LinkMonitor;
    interface PacketAcknowledgements;
  }

#ifdef DYMO_MONITORING
  provides {
    interface DymoMonitor;
  }
#endif
}

implementation {
  components DymoTableC, DymoEngineM, DymoPacketM;
  //components new ConfigStorageC(VOLUME_DYMODATA);  //Modified by Antonio Rosa. Now we save/read num_seq to/from internal EEPROM
  components InternalFlashC, new TimerMilliC() as RespTimer;
  components LedsC;

  SplitControl = DymoEngineM.SplitControl;
  Packet       = DymoPacketM.Packet;
  AMPacket     = DymoEngineM.AMPacket;
  AMSend       = DymoEngineM.AMSend;
  Receive      = DymoEngineM.Receive;
  LinkMonitor  = DymoTableC.LinkMonitor;
 // PacketAcknowledgements 		 = DymoEngineM.Ack;	
  DymoEngineM.Ack  = PacketAcknowledgements;

  DymoEngineM.DymoPacket   -> DymoPacketM;
  DymoEngineM.RoutingTable -> DymoTableC;
  DymoEngineM.DymoTable    -> DymoTableC;
  DymoEngineM.RespTimer    -> RespTimer; 
  DymoEngineM.Leds		-> LedsC;
//  DymoEngineM.Mount         -> ConfigStorageC;  // Modified by Antonio Rosa. Now we save/read num_seq to/from internal EEPROM
  //DymoEngineM.ConfigStorage -> ConfigStorageC;	 // Modified by Antonio Rosa. Now we save/read num_seq to/from internal EEPROM
  DymoEngineM.InternalFlash    -> InternalFlashC.InternalFlash;
    
#ifdef DYMO_MONITORING
  components new TimerMilliC();
  DymoMonitor = DymoEngineM.DymoMonitor;
  DymoEngineM.Timer     -> TimerMilliC;
#endif
}
