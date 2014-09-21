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
#include <random.h>

#define BIT_RATE 57600
#define BIT_TIME XS1_TIMER_HZ / BIT_RATE

// If a positive output turns the beam off (closes the shutter) (SuperSTEM1/Normal)
//#define ON_STATE 0
//#define OFF_STATE 1

/* If a positive output turns the beam on (opens the shutter) (SuperSTEM2) */
#define ON_STATE 1
#define OFF_STATE 0

// 128 bits/setting.  4Mbits total flash memory.
typedef struct {
	unsigned int setupTime ;
	unsigned int onTime ;
	// added 20140915 for compressed sensing applications - waits for defined number of input pulses before advancing to next setting.
	//    implies sync - it is an error to have random gap > 0 and sync != 1.
	unsigned int max_random_gap;
	unsigned char sync;
	unsigned char setupUnits;
	unsigned char onUnits;
} timeset ;

timeset ON_SETTING={1 /*setup*/, 1 /*onTime*/, 0 /*gap*/, 0 /*sync_ticks (unsync)*/, 'o' /*setupUnits*/, 'o'/*onUnits*/};
timeset OFF_SETTING={1 /*setup*/, 1 /*onTime*/, 0 /*gap*/, 0 /*sync_ticks (unsync)*/,'x' /*setupUnits*/, 'x'/*onUnits*/};

in port rxd = PORT_UART_RX;
out port txd = PORT_UART_TX;
on stdcore[1] : out port out_port1 = XS1_PORT_1B;
on stdcore[1] : out port out_port2 = XS1_PORT_1A;
on stdcore[1] : out port clock_out = XS1_PORT_1D;
on stdcore[1] : in port ext_sync = XS1_PORT_1C;

// main thread functions:
// comm thread
void getSettings(chanend set_ch1, chanend go_ch1, chanend interrupt_ch);
void output_master(chanend set_ch, chanend go_ch, chanend interrupt_ch, out port out_port);

// Time delay functions:
// Determine the amount of time to wait.  Depending on amount of time to wait,
// calls either wait function to kill lots of time or fast_output for small amounts.
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
	chan set_ch1, go_ch1, interrupt_ch;
	par{
		// getSettings runs on stdcore[0] because the UART ports are on that core.
		on stdcore[0]: getSettings(set_ch1, go_ch1, interrupt_ch);
		// these two functions are on stdcore[1] because their ports are wired to that core.
		on stdcore[1]: output_master(set_ch1, go_ch1, interrupt_ch, out_port1);
	}
	return 0;
}

// comm thread
void getSettings(chanend set_ch1, chanend go_ch1, chanend interrupt_ch){
	unsigned int nSettings;
	int pDone;
	int STOP=1;
	int GO=0;
	int is_sync=0;
	timer tmr;
	unsigned time;

	while(1)
		{
			select
			{
				case go_ch1 :> pDone: // primary process thread is ready for another round
				{
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
							break;
						}
					}
					// tell processes to wait for new input
					go_ch1 <: STOP;
					// tell computer you're ready for data
					txByte(255);
					nSettings=rxInt(); // get number of settings
					// tell number of settings to process threads

					// nsettings = 0 means close shutter
					if (nSettings == 0){
						// dispatch one setting to either output thread
						set_ch1 <: (unsigned char)1;
						// tell the primary output to blank
						set_ch1 <: OFF_SETTING;
						is_sync=0;
					}

					// nsettings = 255 means open shutter
					else if (nSettings == 255){
						// dispatch one setting to either output thread
						set_ch1 <: (unsigned char)1;
						// tell the primary output to blank
						set_ch1 <: ON_SETTING;
						is_sync=0;
					}

					// anything else is a series of on/off sequences
					else
					{
					    timeset setting;

						is_sync=0;

						set_ch1 <: nSettings;

						// acquire each sequence of settings
                        for (int i = 0; i < nSettings; i += 1)
                        {
                            setting.setupTime=rxInt();
                            setting.onTime=rxInt();
                            setting.max_random_gap=rxInt();
                            setting.sync=rxByte();
                            setting.setupUnits=rxByte();
                            setting.onUnits=rxByte();

                            if (setting.max_random_gap > 0 || setting.sync > 0)
                            {
                                is_sync=1;
                            }
                            set_ch1 <: setting;
                        }
					}
					break;
				}
			}
		}
}

void output_master(chanend set_ch, chanend go_ch, chanend interrupt_ch, out port out_port) {
	unsigned char nSettings=1;
	timeset settings[255];
	int DONE=1;
	int stop=0;
	int set_ct, break_loop;

	// devilish seed for random numbers
	const unsigned seed = 666;
	random_generator_t generator = random_create_generator_from_seed(seed);

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
					setDelay(20,'u',out_port,OFF_STATE,OFF_STATE);
					// loop through any number of settings, making sure that master
					// and worker threads are in sync.
					//for (unsigned j = 0; j < settings[set_ct].nacqs; j += 1) loop_sync :> sync;
					break;
				}
				case 111: {
					// case 'o': deactivate the shutter (turn on beam)
					setDelay(20,'u',out_port,ON_STATE,ON_STATE);
					// loop through any number of settings, making sure that master
					// and worker threads are in sync.
					//for (unsigned j = 0; j < settings[set_ct].nacqs; j += 1) loop_sync :> sync;
					break;
				}
				default: {
					// Not 'x' or 'o' - we have a real setting here!  Excitement abounds!
					// make sure the shutter is off while waiting for any sync signal
					out_port <: OFF_STATE;
					// camera hardware sync signal
					// wait until camera signals that it is acquiring
					if (settings[set_ct].max_random_gap > 0 || settings[set_ct].sync > 0)
					{
						select {
							//waits for sync signal
							case ext_sync when pinseq (1) :> void:
							{
								// wait to receive a sync pulse from ext_sync1
								break;
							}
							// Any interrupt will set break_loop to 1 here.
							// That will break the settings loop.
							case interrupt_ch :> break_loop:
							{
								// go to beginning of settings loop, which should not
								// enter another iteration now that break_loop is 1.
								continue;
								break;
							}
						}
					}
                    //for (unsigned j = 0; j < settings[set_ct].nacqs; j += 1){
                        // output clock signal - advance 1 pixel
                        clock_out <: 1;
                        setDelay(settings[set_ct].setupTime,settings[set_ct].setupUnits,out_port,OFF_STATE,OFF_STATE);
                        setDelay(settings[set_ct].onTime,settings[set_ct].onUnits,out_port,ON_STATE,OFF_STATE);
                        // reset clock signal
                        clock_out <: 0;
                    //}

                    // compressed sensing stuff - only kicks in if max_random_gap > 0.  only makes sense if sync is also true, but we don't check that here.
                    if (settings[set_ct].max_random_gap > 0)
                    {
                        unsigned int gap = random_get_random_number(generator) % settings[set_ct].max_random_gap;
                        // For compressive sensing: wait for multiple external clock inputs - these are each blanked pixels.
                        for (unsigned tick=0; tick < gap; tick += 1)
                        {
                            // Wait for sync pulse edge to fall
                            select
                            {
                                //waits for sync signal
                                case ext_sync when pinseq (0) :> void:
                                {
                                    // wait to receive a sync pulse from ext_sync1
                                    break;
                                }
                                // Any interrupt will set break_loop to 1 here.
                                // That will break the settings loop.
                                case interrupt_ch :> break_loop:
                                {
                                    // go to beginning of settings loop, which should not
                                    // enter another iteration now that break_loop is 1.
                                    continue;
                                    break;
                                }
                            }

                            //waits for sync signal to rise
                            select
                            {
                                case ext_sync when pinseq (1) :> void:
                                {
                                    // wait to receive a sync pulse from ext_sync1
                                    break;
                                }
                                // Any interrupt will set break_loop to 1 here.
                                // That will break the settings loop.
                                case interrupt_ch :> break_loop:
                                {
                                    // go to beginning of settings loop, which should not
                                    // enter another iteration now that break_loop is 1.
                                    continue;
                                    break;
                                }
                            }
                        }
                    }

                    // camera hardware sync signal
                    // wait until camera signals that it is done acquiring.
                    if (settings[set_ct].max_random_gap > 0 || settings[set_ct].sync > 0)
                    {
                        select {
                            //waits for sync signal
                            case ext_sync when pinseq (0) :> void:
                            {
                                break;
                            }
                            case interrupt_ch :> break_loop:
                            {
                                continue;
                                break;
                            }
                            }
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
			// 1E5 cycles/msec
			ticks=time*100000;
			out_port <: signal;
			wait(ticks);
			out_port <: endstate;
			break;
		}
		case 115: //seconds, lower-case s
		{
			// if time is longer than 2 seconds, the counter is in danger of overflow.
			// to avoid this, divide by 2 and wait in multiples of 2 seconds, then
			// finally wait for the remainder time.
			if (time>2) {
				carry=time/2;
			}

			out_port <: signal;
			ticks = 2*100*1000*1000;
			for (int cnt = 0; cnt < carry; cnt++){
				// wait 2 sec
				// 1E8 cycles/sec
				wait(ticks);
				}
			// wait remainder seconds
			ticks = (time%2)*100*1000*1000;
			wait(ticks);
			// output end state
			out_port <: endstate;
			break;
		}
		case 77: //minutes, captial M
		{
			// wait in multiples of 2 seconds (three intervals per minute)
			carry=time*30;
			out_port <: signal;
			for (int cnt = 0; cnt < carry; cnt += 1){
				// wait 2 sec
				wait(2*100*1000*1000);
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
