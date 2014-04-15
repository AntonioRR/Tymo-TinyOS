/*
 * Copyright (c) 2007 Romain Thouvenin <romain.thouvenin@gmail.com>
 * Published under the terms of the GNU General Public License (GPLv2).
 */





#include "routing.h"



/**
 * ForwardingEngineM - Handles received packets of a certain protocol
 * in a multihop context.  The component uses a route selector to
 * determine if the packet should be forwarded or passed to the upper
 * layer. If the packet is forwarded, the next hop is given by the
 * route selector.
 *
 * @author Romain Thouvenin
 */

//TODO probably need a lot of cleaning, and to be moved elsewhere


generic module ForwardingEngineM () {

  provides { //For the upper layer
    interface AMSend[uint8_t id];
    interface Receive[uint8_t id];
    interface Intercept[uint8_t id];
    interface LinkMonitor;
  }
  uses {
    interface RouteSelect; 
    interface AMSend as SubSend;
    interface AMPacket;  
    interface Packet as PPacket; 
    interface Packet as SubPacket;
    interface PacketAcknowledgements as Acks;
    interface Receive as SubReceive;
    interface Timer<TMilli> as Timer;
    interface Leds;
    interface  Timer<TMilli> as DelayTimer;
    
    	#ifdef LOW_POWER_LISTENING
  	 interface LowPowerListening;
  	
  	#endif
    
   
  }

  provides interface MHControl;
}

implementation {
  message_t buf; //first available, do NOT use it
  message_t * avail = &buf;
  message_t * waiting;
   message_t *currentReSendMsg;
  uint8_t typebuf;
  uint8_t lenWaiting;
  uint8_t amWaiting = 0;
  am_addr_t bufAddr;
  am_addr_t * addrWaiting;
  bool lockAvail, lockWaiting;
  uint32_t wait_time;
  bool acks;
  uint8_t count = 0;
  uint8_t  count_time = 0;

#ifdef LOW_POWER_LISTENING

  enum {
    WAIT_BEFORE_RETRY = LPL_DEF_REMOTE_WAKEUP * 2,  // without low power 100, with low power 1024.
  //  MAX_WAIT = 10 * WAIT_BEFORE_RETRY,
    COUNT_WAIT = 5,   //wait for to get a route to target
    MAX_RETX = 10,
    TIMER_RETX_MSG = 50
  };

# else
 enum {
    WAIT_BEFORE_RETRY = 100,  // without low power 100, with low power 1024.
  //  MAX_WAIT = 10 * WAIT_BEFORE_RETRY,
    COUNT_WAIT = 5,
     MAX_RETX = 5,
    TIMER_RETX_MSG = 50
  };

#endif


	command error_t AMSend.send[uint8_t am](am_addr_t addr, message_t * msg, uint8_t len){

		#ifdef LOW_POWER_LISTENING
		if (call AMPacket.destination(msg)!= 1)
			call LowPowerListening.setRemoteWakeupInterval(msg, LPL_DEF_REMOTE_WAKEUP);
		else 
			call LowPowerListening.setRemoteWakeupInterval(msg, 0);
		#endif

		switch(call RouteSelect.selectRoute(msg, &addr, &am)){
			case FW_SEND:
				
				call PPacket.setPayloadLength(msg, len);
				acks = DYMO_LINK_FEEDBACK && (call Acks.requestAck(msg) == SUCCESS);
				typebuf = am;
				//currentSendMsg = msg; //adding by Antonio Rosa

				return call SubSend.send(call AMPacket.destination(msg), msg, call SubPacket.payloadLength(msg));
				break;
			case FW_WAIT: 
				atomic {
					if(lockWaiting)
					  return EBUSY;
					lockWaiting = TRUE;
				}
				
				waiting = msg;
				amWaiting = am;
				call PPacket.setPayloadLength(msg, len);
				lenWaiting = call SubPacket.payloadLength(msg);
				bufAddr = addr;
				addrWaiting = &bufAddr;
				wait_time = 0;
				count_time = 0;
				call Timer.stop(); //Adding by Antonio Rosa
				call Timer.startOneShot(WAIT_BEFORE_RETRY); 
				dbg("fwe", "FE: I'll retry later.\n");
				//return SUCCESS;
				return EBUSY; // waiting a route. not sended. modified by Antonio Rosa.
				break;

			default: //We don't allow sending to oneself
				return FAIL; 
			break;
	    }
	}



	event message_t * SubReceive.receive(message_t * msg, void * payload, uint8_t len){
		#ifdef LOW_POWER_LISTENING
			if (call AMPacket.destination(msg)!= 1)
				call LowPowerListening.setRemoteWakeupInterval(msg, LPL_DEF_REMOTE_WAKEUP);
			else 
				call LowPowerListening.setRemoteWakeupInterval(msg, 0);
		#endif

		
		dbg("fwe", "FE: Received a message from %u\n", call AMPacket.source(msg));
		signal MHControl.msgReceived(msg);
		switch(call RouteSelect.selectRoute(msg, NULL, &typebuf)){
			case FW_SEND:
				atomic {
					if (lockAvail) {
						dbg("fwe", "FE: Discarding a received message because no avail buffer.\n");
						return msg;
					}
					lockAvail = TRUE;
				}
				if ( signal Intercept.forward[typebuf](msg, call PPacket.getPayload(msg, call PPacket.payloadLength(msg)), call PPacket.payloadLength(msg)) ) {
					acks = DYMO_LINK_FEEDBACK && (call Acks.requestAck(msg) == SUCCESS);
					// currentSendMsg = msg; //adding by Antonio Rosa
					call SubSend.send(call AMPacket.destination(msg), msg, len);
				}
				return avail;

			case FW_RECEIVE:
				dbg("fwe", "FE: Received a message, signaling to upper layer.\n");
				payload = call PPacket.getPayload(msg, call PPacket.payloadLength(msg));
				return signal Receive.receive[typebuf](msg, payload, call PPacket.payloadLength(msg));

				case FW_WAIT:
				atomic {
					if(lockAvail || lockWaiting) {
						dbg("fwe", "FE: Discarding a received message because no avail or wait buffer.\n");
						return msg;
					}
					lockAvail = lockWaiting = TRUE;
				}
				waiting = msg;
				lenWaiting = len;
				addrWaiting = NULL;
				wait_time = 0;
				count_time = 0;
				call Timer.stop(); //Adding by Antonio Rosa
				call Timer.startOneShot(WAIT_BEFORE_RETRY);
				return avail;

			default:
				dbg("fwe", "FE: Discarding a received message because I don't know what to do.\n");
				return msg;
		}
	}
  
	event void SubSend.sendDone(message_t * msg, error_t e){
		currentReSendMsg = msg;   //
		dbg("fwe", "FE: Sending done...\n");
		if ((e == SUCCESS) && acks) {          //message sent.
			if( !(call Acks.wasAcked(msg)) ){   // Msg was not acknowledged.

				e = FAIL;
				dbg("fwe", "FE: The message was not acked => FAIL.\n");
				//signal MHControl.sendFailed(msg, 2);
				/*************************************************************************************************/
				//Adding by Antonio Rosa. Now we try to send the message several times
				//	acks = DYMO_LINK_FEEDBACK && (call Acks.requestAck(msg) == SUCCESS);
				//	typebuf = call AMPacket.type(msg);
				//	call SubSend.send(call AMPacket.destination(msg), msg, call SubPacket.payloadLength(msg));

				//	  post ReSend();
				// return;
				count ++;  //Ack Count ++
				if (count > MAX_RETX){
					currentReSendMsg = NULL;
					count = 0;
					signal MHControl.sendFailed(msg, 2);
					signal LinkMonitor.brokenLink(call AMPacket.destination(msg));
					    if (lockAvail) {
						      avail = msg;
						      atomic {
						      lockAvail = FALSE;
						 }
					 dbg("fwe", "FE: No need to signal sendDone.\n");
						} else {
							dbg("fwe", "FE: Signaling sendDone.\n");
							if (amWaiting) {
								signal AMSend.sendDone[amWaiting](msg, FAIL); //NOT acknowledged.
								amWaiting = 0;
							} 
							else 
								signal AMSend.sendDone[typebuf](msg, FAIL); // NOT acknowledged.
							
							atomic {
							lockWaiting = FALSE;
							}
						 }	
					return;	
				}
				call DelayTimer.startOneShot(TIMER_RETX_MSG);  //Not ack and them we retry to send msg with the same route.
				return;	
			} 

			else {   // Msg was acknowledged
				count = 0;  //Adding by Antonio Rosa. 
				signal LinkMonitor.refreshedLink(call AMPacket.destination(msg));
				currentReSendMsg = NULL;
			}
		} 

		else if (e != SUCCESS) {   //message was not sent.
			dbg("fwe", "FE: ...but failed!\n");
			signal MHControl.sendFailed(msg, 1);
		}

		if (lockAvail) {  //free buffer
			avail = msg;
			atomic {
			lockAvail = FALSE;
			}
			dbg("fwe", "FE: No need to signal sendDone.\n");
		} 
		
		else {

			dbg("fwe", "FE: Signaling sendDone.\n");
			if (amWaiting) {
				signal AMSend.sendDone[amWaiting](msg, e);
				amWaiting = 0;
			} 
			
			else {
				signal AMSend.sendDone[typebuf](msg, e);
			}
			atomic {
			lockWaiting = FALSE;
			}
		}
	}

	event void DelayTimer.fired(){ //has route but it have not been ack.
		
		acks = DYMO_LINK_FEEDBACK && (call Acks.requestAck(currentReSendMsg) == SUCCESS);
		//typebuf = call AMPacket.type(currentReSendMsg);
		call SubSend.send(call AMPacket.destination(currentReSendMsg), currentReSendMsg, call SubPacket.payloadLength(currentReSendMsg));	

	}


	event void Timer.fired(){  //did not have route.
		
		switch(call RouteSelect.selectRoute(waiting, addrWaiting, &amWaiting)){
			case FW_SEND:
				dbg("fwe", "FE: I'm retrying to send my message.\n");
				if (addrWaiting) {
				// currentSendMsg = waiting; //adding by Antonio Rosa
					acks = DYMO_LINK_FEEDBACK && (call Acks.requestAck(waiting) == SUCCESS);  //adding by Antonio Rosa because it was not ack.
					call SubSend.send(call AMPacket.destination(waiting), waiting, lenWaiting);
				} 
				else if ( signal Intercept.forward[amWaiting](waiting, 
					      call PPacket.getPayload(waiting, call PPacket.payloadLength(waiting)), 
					      call PPacket.payloadLength(waiting)) ) {
				//currentSendMsg = waiting; //adding by Antonio Rosa			      
				call SubSend.send(call AMPacket.destination(waiting), waiting, lenWaiting);
				}
				call Timer.stop();
			break;

			case FW_WAIT:
			// Modificado por Antonio
				
				
				if(count_time < COUNT_WAIT){
					count_time ++;
					call Timer.stop();  //Adding by Antonio Rosa
					call Timer.startOneShot(WAIT_BEFORE_RETRY);
					return;
					break;
				}

				else{
					count_time = 0;
					call Timer.stop();
				}

			default:
				if(addrWaiting){
					signal AMSend.sendDone[amWaiting](waiting, FAIL);
					//call Leds.led2Toggle();
				}
				if(lockAvail){
					avail = waiting;
					atomic {
						lockAvail = FALSE;
					}
				}
				atomic {
					lockWaiting = FALSE;
				}
			break;
		}
	}

	command error_t AMSend.cancel[uint8_t am](message_t *msg){
		if(lockWaiting){
			count_time = 0;
			call Timer.stop();
			atomic {
				lockWaiting = FALSE;
				// currentSendMsg = NULL; //adding by Antonio Rosa
			}
			return SUCCESS;
		} 
		else {
			return call SubSend.cancel(msg);
		}
	}

	command void * AMSend.getPayload[uint8_t am](message_t *msg, uint8_t len){
		return call PPacket.getPayload(msg, len);
	}


	command uint8_t AMSend.maxPayloadLength[uint8_t am](){
		return call PPacket.maxPayloadLength();
	}


  /*** defaults ***/

 default event message_t * Receive.receive[uint8_t am](message_t * msg, void * payload, uint8_t len){
   return msg;
 }

 default event void AMSend.sendDone[uint8_t am](message_t * msg, error_t e){}

 default event bool Intercept.forward[uint8_t am](message_t * msg, void * payload, uint8_t len){
   return TRUE;
 }

 default event void MHControl.msgReceived(message_t * msg){ }

 default event void MHControl.sendFailed(message_t * msg, uint8_t why){ }

 default event void LinkMonitor.brokenLink(addr_t neighbor){ }
 
 default event void LinkMonitor.refreshedLink(addr_t neighbor){ }  //add by Antonio. For eliminate Tymo Ack
}
