/*
 * ============================================================================
 * Name        : fbsMT.xc
 * Description : Fast Beam Shutter control.
 * 					This code is the multithreaded modification of the original.
 * 					It listens for input on one thread, and processes it on another.
 * ============================================================================
 */

// To-do:
//  Timeout for if input gets botched?  return shutter to on/off?

#include <xs1.h>
#include <print.h>
#include <platform.h>

#define BIT_RATE 19200
#define BIT_TIME XS1_TIMER_HZ / BIT_RATE


// If a positive output turns the beam off (closes the shutter)
#define ON_STATE 0
#define OFF_STATE 1

/* If a positive output turns the beam on (opens the shutter) */
//#define ON_STATE 1
//#define OFF_STATE 0

typedef struct {
	unsigned int nacqs ;
	unsigned int setupTime ;
	unsigned char setupUnits;
	unsigned int onTime ;
	unsigned char onUnits;
	unsigned char sync;
	unsigned char output_interleave;
} timeset ;

timeset ON_SETTING={1,1,'o',1,'o',(char)0,(char)0};
timeset OFF_SETTING={1,1,'x',1,'x',(char)0,(char)0};

in port rxd = PORT_UART_RX;
out port txd = PORT_UART_TX;
on stdcore[1] : out port out_port1 = XS1_PORT_1A;
on stdcore[1] : out port out_port2 = XS1_PORT_1B;
on stdcore[1] : in port ext_sync1 = XS1_PORT_1C;
on stdcore[1] : in port ext_sync2 = XS1_PORT_1D;

int uart_getc(unsigned timeout);
unsigned char rxByte(void);
unsigned int rxInt(void);
void txByte(unsigned char c);
void txInt(unsigned int num);
void output_usec(int time, out port out_port, unsigned char signal, unsigned char endstate);
void output_nsec(int time, out port out_port, unsigned char signal, unsigned char endstate);
void setDelay(unsigned int time, unsigned char units, out port out_port, unsigned char signal, unsigned char endstate);
void getNumSettings(chanend nSetOut);
void getSettings(chanend set_ch1, chanend go_ch1, chanend set_ch2, chanend go_ch2);
void output_master(chanend set_ch, chanend go_ch, chanend thread_sync, chanend loop_sync, out port out_port);
void output_worker(chanend set_ch, chanend go_ch, chanend thread_sync, chanend loop_sync, out port out_port);
void wait(int ticks);
void chipReset( void );

int main(void){
	chan set_ch1, set_ch2, go_ch1, go_ch2, thread_sync, loop_sync;
	par{
		on stdcore[0]: getSettings(set_ch1, go_ch1, set_ch2, go_ch2);
		on stdcore[1]: output_master(set_ch1, go_ch1, thread_sync, loop_sync, out_port1);
		on stdcore[1]: output_worker(set_ch2, go_ch2, thread_sync, loop_sync, out_port2);
	}
	return 0;
}

void getSettings(chanend set_ch1, chanend go_ch1, chanend set_ch2, chanend go_ch2){
	timer tmr;
	unsigned time;
	unsigned char nSettings;
	// the settings as received from the serial port
	timeset settings[255];
	// the settings sent to the first process thread (controls out port 1)
	timeset set_out_1[255];
	// the settings sent to the second process thread (controls out port 2)
	timeset set_out_2[255];
	int pDone;
	int STOP=1;
	int GO=0;
	int ctr;
	int is_sync=0;

	while(1)
		{
			select
			{
				case go_ch1 :> pDone: // primary process thread is ready for another round
				{
					go_ch2 :> pDone;
					go_ch1 <: GO;
					go_ch2 <: GO;
					break;
				}
				// comm received, incoming data
				// received data should be 0.  This
				case rxd when pinsneq(1) :> void:  //
				{
					// if any channel is being used to synchronize, then reset the chip when comm is received.
					// this is done to work around locking up waiting for potentially non-existent sync signal.
					if (is_sync==1) {
						tmr :> time;
						// start bit + 1/2 bit offset (read in middle of bit) +
						//         8 data bits + stop bit
						time += 10*BIT_TIME+BIT_TIME/2;
						tmr when timerafter(time) :> void;
						txByte(0);
						chipReset();
					}
					// wait for process to finish.  This should pretty much always take long enough that
					// the serial comm sync doesn't create any weird received values on the other end.
					select
					{
						case go_ch1 :> pDone:
							{
							go_ch2 :> pDone;
							break;
							}
						case go_ch2 :> pDone:
							{
							go_ch1 :> pDone;
							break;
							}
					}

					// tell process to wait for new input
					go_ch1 <: STOP;
					go_ch2 <: STOP;
					wait(5000);
					// tell computer you're ready for data
					txByte(255);
					nSettings=rxByte(); // get number of settings
					// tell number of settings to process threads
					// nsettings = 0 means close shutter
					if (nSettings == 0){
						set_ch1 <: (unsigned char)1;
						set_ch2 <: (unsigned char)1;
						set_ch1 <: OFF_SETTING;
						set_ch2 <: ON_SETTING;
						is_sync=0;
					}
					// nsettings = 255 means open shutter
					else if (nSettings == 255){
						set_ch1 <: (unsigned char)1;
						set_ch2 <: (unsigned char)1;
						set_ch1 <: ON_SETTING;
						set_ch2 <: ON_SETTING;
						is_sync=0;
					}
					// anything else is a series of on/off sequences
					else
					{
						// acquire each sequence of settings
						for (int i = 0; i < nSettings; i += 1) {
							settings[i].nacqs=rxInt();
							settings[i].setupTime=rxInt();
							settings[i].setupUnits=rxByte();
							settings[i].onTime=rxInt();
							settings[i].onUnits=rxByte();
							settings[i].sync=rxByte();
							settings[i].output_interleave=rxByte();
						}
						ctr=0;
						is_sync=0;
						while (ctr < nSettings) {
							if (settings[ctr].output_interleave==1){
								set_out_1[ctr] = settings[ctr];
								set_out_2[ctr] = settings[ctr+1];
								if (set_out_1[ctr].nacqs != set_out_2[ctr].nacqs) chipReset();
								ctr+=1;
								nSettings-=1;
							}
							else {
								set_out_1[ctr] = settings[ctr];
								// If not interleaving outputs, keep output 2 ON!
								settings[ctr].onUnits='o';
								set_out_2[ctr] = settings[ctr];
								ctr+=1;
							}
							if ((settings[ctr].sync>0)) {
								is_sync=1;
							}
						}
						set_ch1 <: nSettings;
						set_ch2 <: nSettings;
						for (int i=0; i < nSettings; i+=1) {
							set_ch1 <: set_out_1[i];
							set_ch2 <: set_out_2[i];
						}
					}
					break;
				}
			}
		}
}

void output_master(chanend set_ch, chanend go_ch, chanend thread_sync, chanend loop_sync, out port out_port) {
	unsigned char nSettings=1;
	timeset settings[255];
	int stop;
	int DONE=1;
	int sync=1;

	settings[0]=ON_SETTING;

	while (1) {
		for (int i = 0; i < nSettings; i+=1) {
			for (unsigned j = 0; j < settings[i].nacqs; j += 1){
				// if settings says turn off, turn off for 250 msec, then stay off
				if (settings[i].onUnits=='x') setDelay(250,'m',out_port,OFF_STATE,OFF_STATE);
				else if (settings[i].onUnits=='o') setDelay(250,'m',out_port,ON_STATE,ON_STATE);
				else {
					// make sure the shutter is off while waiting for sync signal
					out_port <: OFF_STATE;
					// camera hardware sync signal
					// wait until camera signals that it is acquiring
					if (settings[i].sync==1) {
							//waits for sync signal
							ext_sync1 when pinseq (1) :> void;
							// outputs sync signal to worker thread
							thread_sync <: sync;
							}
					else if (settings[i].sync==2) {
						ext_sync2 when pinseq (1) :> void;
						thread_sync <: sync;
						}

					setDelay(settings[i].setupTime,settings[i].setupUnits,out_port,OFF_STATE,OFF_STATE);
					setDelay(settings[i].onTime,settings[i].onUnits,out_port,ON_STATE,OFF_STATE);

					// camera hardware sync signal
					// wait until camera signals that it is done acquiring.
					if (settings[i].sync==1) {
							// waits for sync signal
							ext_sync1 when pinseq (0) :> void;
							// outputs sync signal to worker thread
							thread_sync <: sync;
							}
					else if (settings[i].sync==2) {
						ext_sync2 when pinseq (0) :> void;
						thread_sync <: sync;
						}
				}
				// Wait until worker thread is done with this loop
				loop_sync :> sync;
			}
		}
		// tell comm thread you're done
		go_ch <: DONE;
		// ask comm thread whether or not to go again.
		go_ch :> stop;
		if (stop == DONE) {
			// read the number of settings from getSettings
			set_ch :> nSettings;
			for (int i = 0; i < nSettings; i+=1) {
				set_ch :> settings[i];
			}
		}
	}
}

void output_worker(chanend set_ch, chanend go_ch, chanend thread_sync, chanend loop_sync, out port out_port) {
	unsigned char nSettings=1;
	timeset settings[255];
	int stop;
	int DONE=1;
	int sync=1;

	settings[0]=ON_SETTING;

	while (1) {
		for (int i = 0; i < nSettings; i+=1) {
			for (unsigned j = 0; j < settings[i].nacqs; j += 1){
				// camera hardware sync signal
				// wait until camera signals that it is acquiring
				if (settings[i].sync>0) {
					out_port <: ON_STATE;
					thread_sync :> sync;
				}
				if (settings[i].onUnits=='x') out_port <: OFF_STATE;
				else if (settings[i].onUnits=='o') out_port <: ON_STATE;
				else {
					// make sure the shutter is off while waiting for sync signal

					setDelay(settings[i].setupTime,settings[i].setupUnits,out_port,OFF_STATE,OFF_STATE);
					setDelay(settings[i].onTime,settings[i].onUnits,out_port,ON_STATE,OFF_STATE);

				}
				// camera hardware sync signal
				// wait until camera signals that it is done acquiring.
				if (settings[i].sync>0) thread_sync :> sync;
				// tell master thread you're done with this loop
				loop_sync <: sync;
			}
		}
		// tell comm thread you're done
		go_ch <: DONE;
		// ask comm thread whether or not to go again.
		go_ch :> stop;
		if (stop == DONE) {
			// read the number of settings from getSettings
			set_ch :> nSettings;
			for (int i = 0; i < nSettings; i+=1) {
				set_ch :> settings[i];
			}
		}
	}
}

void setDelay(unsigned int time, unsigned char units, out port out_port, unsigned char signal, unsigned char endstate){
	unsigned int carry=0;
	switch(units){
		case 77: //minutes, captial M
			carry=time*60000000/320;
			out_port <: signal;
			for (int cnt = 0; cnt < carry; cnt += 1){
					wait(32000);
				}
			output_usec(time*60000000%320, out_port, signal, endstate);
			break;
		case 115: //seconds, lower-case s
			carry=time*1000000/320;
			out_port <: signal;
			for (int cnt = 0; cnt < carry; cnt += 1){
				wait(32000);
				}
			output_usec(time*1000000%1280, out_port, signal, endstate);
			break;
		case 109: //milliseconds, lower-case m
			carry=time*1000/320;
			out_port <: signal;
			for (int cnt = 0; cnt < carry; cnt += 1){
					wait(32000);
					}
			output_usec(time*1000%320, out_port, signal, endstate);
			break;
		case 117: //microseconds, lower-case u
			carry=time/320;
			if (carry>0) {
				out_port <: signal;
				for (int cnt = 0; cnt < carry; cnt += 1){
					wait(32000);
					}
			}
			output_usec(time%320, out_port, signal, endstate);
			break;
		case 110: //nanoseconds, lower-case n
			// time / 10 is because there are 10 ns per clock tick.
			// division done here to allow faster switching in the actual function.
			time=time/10;
			carry=time/32000;
			if (carry>0) {
				out_port <: signal;
				for (int cnt = 0; cnt < carry; cnt += 1){
					wait(32000);
					}
			}

			output_nsec(time%32000, out_port, signal, endstate);
			break;
		default:
			chipReset();
			break;
	}
}

void chipReset(void)
{
  unsigned x;

  read_sswitch_reg(get_core_id(), 6, x);
  write_sswitch_reg(get_core_id(), 6, x);
}

void output_usec(int time, out port out_port, unsigned char signal, unsigned char endstate)
{
	// more precise function for killing time.  Should be accurate to 1 us.
	int portTime;
	out_port <: signal @ portTime;
	// time * 100 is because there are 100 clock ticks per us.
	portTime += time*100;
	/* this @ portTime is only a 16 bit counter, it will wrap at 65536 (at best)
	* To be safe, I have made it assume that it only has 15 bits, and that no
	* number passed to is ever allowed to be greater than 32000.  */
	out_port @ portTime <: endstate;  // Turn port to endstate after time has elapsed
}

void output_nsec(int time, out port out_port, unsigned char signal, unsigned char endstate)
{
	/* The extreme function for killing time.  The absolute minimum is 180 ns
	 * (from outputting the signal at first and reading the current portTime,
	 * to adding the time, to outputting the new value at the incremented
	 * portTime takes 18 clock cycles (10 ns per cycle).  Only a faster XS1 would
	 * allow you to get better time.
	 */
	int portTime;
	out_port <: signal @ portTime;
	portTime += time;
	/* this @ portTime counter should never wrap - if you want several thousand ns,
	 * why aren't you using the output_usec function instead?
	 */
	out_port @ portTime <: endstate;  // Turn port to endstate after time has elapsed
}


void wait(int ticks){
	// generic, less precise function to kill time.  better for longer periods of time, though.
	timer tmr;
	unsigned int time;
	tmr :> time;
	time += ticks;
	tmr when timerafter ( time ) :> void ;
}

// UART receive function with timeout borrowed from open1541 project.
// http://bitbucket.org/skoe/open1541/src/tip/src/uart/uart_rx.xc
int uart_getc(unsigned timeout)
{
    unsigned i, time, rx_value;
    timer    tmr;

    tmr :> time;
    time += timeout;

    // wait until RX goes high (idle or rest of previous stop bit)
    select
    {
    case timeout => tmr when timerafter(time) :> void:
    	return -1;

    case rxd when pinsneq(0) :> void:
        break;
    }

    // wait until RX goes low (edge of start bit)
    select
    {
    case timeout => tmr when timerafter(time) :> void:
        return -1;

    case rxd when pinsneq(1) :> void:
        break;
    }

    // receive 8 bits
    tmr :> time;
    time += BIT_TIME + BIT_TIME / 2;
    rx_value = 0;
    for (i = 0; i < 8; ++i)
    {
        tmr when timerafter(time) :> void;
        rxd :> >> rx_value;
        time += BIT_TIME;
    }

    //Receive stop bit
    tmr when timerafter(time) :> void;
		select
		{
		case timeout => tmr when timerafter(time) :> void:
			return -1;

		case rxd when pinsneq(0) :> void:
			break;
		}

    return rx_value >> 24;
}

unsigned char rxByte(void)
{
	unsigned char rlt;
	rlt = (unsigned char) (uart_getc(0));
	return rlt;
}

unsigned int rxInt(void)
{
	unsigned char c[4];
	for (int i=0; i<4; i+=1){
		c[i]=rxByte();
	}
	return (int) (c[0]|c[1]<<8|c[2]<<16|c[3]<<24);
}

void txByte(unsigned char c)
{
   unsigned time, data;

   data = c;

   // get current time from port with force out.
   txd <: 1 @ time;

   // Start bit.
   txd <: 0;

   // Data bits.
   for (int i = 0; i < 8; i += 1)
   {
      time += BIT_TIME;
      txd @ time <: >> data;
   }

   // one stop bit
   time += BIT_TIME;
   txd @ time <: 1;

}

void txInt(unsigned int num)
{
	unsigned char c;
	for (int i=0; i<4; i+=1){
		c=(unsigned char)(num>>i*8);
		txByte(c);
	}
}
