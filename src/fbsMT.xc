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

// main thread functions:
// comm thread
void getSettings(chanend set_ch1, chanend go_ch1, chanend set_ch2, chanend go_ch2, chanend interrupt_ch);
void output_master(chanend set_ch, chanend go_ch, chanend thread_sync, chanend interrupt_ch, chanend loop_sync, out port out_port);
void output_worker(chanend set_ch, chanend go_ch, chanend thread_sync, chanend loop_sync, out port out_port);

// Time delay functions:
// Determine the amount of time to wait.  Calls wait function to kill lots of time,
// then makes a final call to fast_output for the last bit of time.
void setDelay(int time, unsigned char units, out port out_port, unsigned char signal, unsigned char endstate);
// Kills time.  Does not affect outputs.
void wait(int ticks);
// Waits very small amounts of time (<320 us).
// outputs signal at init_time, then endstate at fin_time.
void fast_output(short init_time, short fin_time, out port out_port, unsigned char signal, unsigned char endstate);

// Communication functions:
int uart_getc(unsigned timeout);
unsigned char rxByte(void);
unsigned int rxInt(void);
void txByte(unsigned char c);
void txInt(unsigned int num);
void chipReset( void );

// thread dispatch
int main(void){
	chan set_ch1, set_ch2, go_ch1, go_ch2, thread_sync, loop_sync, interrupt_ch;
	par{
		// getSettings runs on stdcore[0] because the UART ports are on that core.
		on stdcore[0]: getSettings(set_ch1, go_ch1, set_ch2, go_ch2, interrupt_ch);
		// these two functions are on stdcore[1] because their ports are wired to that core.
		on stdcore[1]: output_master(set_ch1, go_ch1, thread_sync, interrupt_ch, loop_sync, out_port1);
		on stdcore[1]: output_worker(set_ch2, go_ch2, thread_sync, loop_sync, out_port2);
	}
	return 0;
}

// comm thread
void getSettings(chanend set_ch1, chanend go_ch1, chanend set_ch2, chanend go_ch2, chanend interrupt_ch){
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
	timer tmr;
	unsigned time;
	int nSet_out;

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

				case go_ch2 :> pDone:
				{
					go_ch1 :> pDone;
					go_ch2 <: GO;
					go_ch1 <: GO;
					break;
				}

				// comm received, incoming data
				case rxd when pinsneq(1) :> void:
				{
					tmr :> time;
					// start bit + 1/2 bit offset (read in middle of bit) +
					//         8 data bits + stop bit
					time += 10*BIT_TIME+BIT_TIME/2;
					tmr when timerafter(time) :> void;
					// if any channel is being used to synchronize, then interrupt any waiting threads
					if (is_sync==1) {
						interrupt_ch <: STOP;
					}
					// wait for process to finish.
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
					// tell processes to wait for new input
					go_ch1 <: STOP;
					go_ch2 <: STOP;
					// tell computer you're ready for data
					txByte(255);
					nSettings=rxByte(); // get number of settings
					// tell number of settings to process threads
					// nsettings = 0 means close shutter
					if (nSettings == 0){
						// dispatch one setting to either output thread
						set_ch1 <: (unsigned char)1;
						set_ch2 <: (unsigned char)1;
						// tell the primary output to blank
						set_ch1 <: OFF_SETTING;
						// the secondary output should stay on
						// unless explicitly specified to be off.
						set_ch2 <: ON_SETTING;
						is_sync=0;
					}
					// nsettings = 255 means open shutter
					else if (nSettings == 255){
						// dispatch one setting to either output thread
						set_ch1 <: (unsigned char)1;
						set_ch2 <: (unsigned char)1;
						// tell the primary output to blank
						set_ch1 <: ON_SETTING;
						// the secondary output should stay on
						// unless explicitly specified to be off.
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
						nSet_out=nSettings;
						while (ctr < nSettings) {
							if ((settings[ctr].sync>0)) {
								is_sync=1;
							}
							if (settings[ctr].output_interleave==1){
								set_out_1[ctr] = settings[ctr];
								set_out_2[ctr] = settings[ctr+1];
								if (set_out_1[ctr].nacqs != set_out_2[ctr].nacqs) chipReset();
								ctr+=1;
								nSet_out-=1;
							}
							else {
								set_out_1[ctr] = settings[ctr];
								// If not interleaving outputs, keep output 2 ON!
								settings[ctr].onUnits='o';
								set_out_2[ctr] = settings[ctr];
								ctr+=1;
							}

						}
						set_ch1 <: nSettings;
						set_ch2 <: nSettings;
						for (int i=0; i < nSet_out; i+=1) {
							set_ch1 <: set_out_1[i];
							set_ch2 <: set_out_2[i];
						}
					}
					break;
				}
			}
		}
}

void output_master(chanend set_ch, chanend go_ch, chanend thread_sync, chanend interrupt_ch, chanend loop_sync, out port out_port) {
	unsigned char nSettings=1;
	timeset settings[255];
	int DONE=1;
	int stop=0;
	int sync, set_ct, break_loop;

	settings[0]=ON_SETTING;

	while (1) {
		// initialize loop counter and loop stop marker
		set_ct = break_loop = 0;
		while ((set_ct<nSettings)&&(!break_loop)) {
			// onUnits is used to determine whether to just switch beam on or off, or
			// to process an actual setting.
			switch (settings[set_ct].onUnits) {
				case 120: {
					// case 'x': activate the shutter (turn off beam)
					setDelay(250,'m',out_port,OFF_STATE,OFF_STATE);
					// loop through any number of settings, making sure that master
					// and worker threads are in sync.
					for (unsigned j = 0; j < settings[set_ct].nacqs; j += 1) loop_sync :> sync;
					break;
				}
				case 111: {
					// case 'o': deactivate the shutter (turn on beam)
					setDelay(250,'m',out_port,ON_STATE,ON_STATE);
					// loop through any number of settings, making sure that master
					// and worker threads are in sync.
					for (unsigned j = 0; j < settings[set_ct].nacqs; j += 1) loop_sync :> sync;
					break;
				}
				default: {
					// Not 'x' or 'o' - we have a real setting here!  Excitement abounds!
					// make sure the shutter is off while waiting for any sync signal
					out_port <: OFF_STATE;
					// camera hardware sync signal
					// wait until camera signals that it is acquiring
					switch (settings[set_ct].sync) {
					case 1: {
						select {
							//waits for sync signal
							case ext_sync1 when pinseq (1) :> void:
							{
								// wait to receive a sync pulse from ext_sync1
								// outputs sync signal to worker thread
								// break_loop should be 0, unless set to 1 previously.
								thread_sync <: break_loop;
								break;
							}
							// Any interrupt will set break_loop to 1 here.
							// That will break the settings loop.
							case interrupt_ch :> break_loop:
							{
								// Tell the worker thread to stop.
								thread_sync <: break_loop;
								// go to beginning of settings loop, which should not
								// enter another iteration now that break_loop is 1.
								continue;
								break;
							}
						}
						break;
					}
					case 2: {
						select {
							case ext_sync2 when pinseq (1) :> void:
							{
								// wait to receive a sync pulse from ext_sync2
								// outputs sync signal to worker thread

								thread_sync <: break_loop;
								break;
							}
							// Any interrupt will set break_loop to 1 here.
							// That will break the settings loop.
							case interrupt_ch :> break_loop:
							{
								// Tell the worker thread to stop.
								thread_sync <: break_loop;
								// go to beginning of settings loop, which should not
								// enter another iteration now that break_loop is 1.
								continue;
								break;
							}
						}
						break;
					}
					default:
						break;
				}
				for (unsigned j = 0; j < settings[set_ct].nacqs; j += 1){
					setDelay(settings[set_ct].setupTime,settings[set_ct].setupUnits,out_port,OFF_STATE,OFF_STATE);
					setDelay(settings[set_ct].onTime,settings[set_ct].onUnits,out_port,ON_STATE,OFF_STATE);
					// Wait until worker thread is done with this loop
					loop_sync :> sync;
				}
				// camera hardware sync signal
				// wait until camera signals that it is done acquiring.
				switch (settings[set_ct].sync) {
					case 1: {
						select {
						//waits for sync signal
						case ext_sync1 when pinseq (0) :> void:
						{
							// outputs sync signal to worker thread
							// break_loop should be 0, unless set to 1 previously.
							thread_sync <: break_loop;
							break;
						}
						case interrupt_ch :> break_loop:
						{
							thread_sync <: break_loop;
							continue;
							break;
						}
						}
						break;
					}
					case 2: {
						select {
							//waits for sync signal
							case ext_sync2 when pinseq (0) :> void:
							{
								// outputs sync signal to worker thread
								thread_sync <: break_loop;
								break;
							}
							case interrupt_ch :> break_loop:
							{
								thread_sync <: break_loop;
								continue;
								break;
							}
						}
						break;
					}
					default:
						// no sync
						break;
					}
					break;
				} // end default case (process settings aside from on/off)
			}
			// loop to next setting
			set_ct+=1;
		}

		// tell comm thread you're done
		go_ch <: DONE;
		// ask comm thread whether or not to go again.
		go_ch :> stop;
		if (stop == DONE) {
			// read the number of settings from getSettings
			set_ch :> nSettings;
			for (int i = 0; i < nSettings; i+=1) {
				// read each setting into thread-local settings buffer
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
		int i=0;
		int break_loop=0;
		while ((i<nSettings)&&(!break_loop)) {
			switch (settings[i].onUnits) {
			case 120:
				out_port <: OFF_STATE;
				if (settings[i].sync>0) {
					// wait until master thread sends sync signal
					// sync signal also indicates whether master has been interrupted.
					// if it has been, break_loop will be obtained as 1 here.
					thread_sync :> break_loop;
					// if master thread has been interrupted, break the settings loop.
					// the continue will return to the while condition check, which
					// will now be false.
					if (break_loop) continue;
				}
				for (unsigned j = 0; j < settings[i].nacqs; j += 1) loop_sync <: sync;
				if (settings[i].sync>0) {
					thread_sync :> break_loop;
					if (break_loop) continue;
				}
				break;
			case 111:
				out_port <: ON_STATE;
				if (settings[i].sync>0) {
					thread_sync :> break_loop;
					if (break_loop) continue;
				}
				for (unsigned j = 0; j < settings[i].nacqs; j += 1) loop_sync <: sync;
				if (settings[i].sync>0) {
					thread_sync :> break_loop;
					if (break_loop) continue;
				}
				break;
			default:
				if (settings[i].sync>0) {
					thread_sync :> break_loop;
					if (break_loop) continue;
				}
				for (unsigned j = 0; j < settings[i].nacqs; j += 1){
					// set output times & execute port activation/deactivation
					setDelay(settings[i].setupTime,settings[i].setupUnits,out_port,OFF_STATE,OFF_STATE);
					setDelay(settings[i].onTime,settings[i].onUnits,out_port,ON_STATE,OFF_STATE);
					// tell master thread you're done with this loop
					loop_sync <: sync;
				}
				if (settings[i].sync>0) {
					thread_sync :> break_loop;
					if (break_loop) continue;
				}
				break;
			}
			i++;
		}

		// tell comm thread you're done
		go_ch <: DONE;
		// ask comm thread whether or not to go again.
		go_ch :> stop;
		if (stop == DONE) {
			// read the number of settings from getSettings
			set_ch :> nSettings;
			for (int i = 0; i < nSettings; i+=1) {
				// read each setting into thread-local settings buffer
				set_ch :> settings[i];
			}
		}
	}
}

void setDelay(int time, unsigned char units, out port out_port, unsigned char signal, unsigned char endstate){
	int carry=0;
	int ticks;
	// these two are used for the fast_output function.  Because it uses port timers, these must be 16-bit ints (short).
	short init_time, fin_time;
	switch(units){
		case 117: //microseconds, lower-case u
		{
			if (time < 5) {
				// for very short delays, use the more precise fast_output function
				// 100 clock cycles per microsecond
				time=time*100;
				out_port <: OFF_STATE @ init_time;
				init_time+=20;
				fin_time=init_time+time;
				fast_output(init_time, fin_time, out_port, signal, endstate);
			}
			else {
				// 100 clock cycles per microsecond
				ticks=time*100;
				out_port <: signal;
				wait(ticks);
				out_port <: endstate;
			}
			break;
		}
		case 110: //nanoseconds, lower-case n
		{
			// time / 10 is because there are 10 ns per clock tick.
			// division done here to allow faster switching in the actual function.
			time=time/10;
			// read out current port timer by timestamped output.
			out_port <: OFF_STATE @ init_time;
			// short additional delay to start time to allow for processing time
			init_time+=20;
			fin_time=init_time+time;
			fast_output(init_time, fin_time, out_port, signal, endstate);
			break;
		}
		case 109: //milliseconds, lower-case m
		{
			ticks=time*100000;
			out_port <: signal;
			wait(ticks);
			out_port <: endstate;
			break;
		}
		case 115: //seconds, lower-case s
		{
			// if time is longer than 30 seconds, the counter is in danger of overflow.
			// to avoid this, divide by 30, and wait in multiples of 30 seconds, then
			// finally wait for the remainder time.
			if (time>20) {
				carry=time/20;
			}

			out_port <: signal;
			for (int cnt = 0; cnt < carry; cnt += 1){
				// wait 20 sec
				wait(2000000000);
				}
			// wait remainder seconds
			wait(time*100000000%20);
			// output end state
			out_port <: endstate;
			break;
		}
		case 77: //minutes, captial M
		{
			// wait in multiples of 20 seconds (three intervals per minute)
			carry=time*3;
			out_port <: signal;
			for (int cnt = 0; cnt < carry; cnt += 1){
				// wait 20 sec
				wait(2000000000);
				}
			out_port <: endstate;
			break;
		}

		default:
		{
			chipReset();
			break;
		}
	}
}

void chipReset(void)
{
  unsigned x;

  read_sswitch_reg(get_core_id(), 6, x);
  write_sswitch_reg(get_core_id(), 6, x);
}

void fast_output(short init_time, short fin_time, out port out_port, unsigned char signal, unsigned char endstate)
{
	/* The extreme function for killing time.  The absolute minimum is 180 ns
	 * (from outputting the signal at first and reading the current portTime,
	 * to adding the time, to outputting the new value at the incremented
	 * portTime takes 18 clock cycles (10 ns per cycle).  Only a faster XS1 would
	 * allow you to get better time.
	 */
	out_port @ init_time <: signal;
	out_port @ fin_time <: endstate;  // Turn port to endstate after time has elapsed
}


void wait(int ticks){
	// generic, less precise function to kill time.  better for longer periods of time, though because it uses a 32-bit counter.
	timer wait_tmr;
	int time;
	wait_tmr :> time;
	time += ticks;
	wait_tmr when timerafter ( time ) :> void ;
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
