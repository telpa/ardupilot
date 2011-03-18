/// -*- tab-width: 4; Mode: C++; c-basic-offset: 4; indent-tabs-mode: t -*-

/*
ArduCopterMega Version 0.1.3 Experimental
Authors:	Jason Short
Based on code and ideas from the Arducopter team: Jose Julio, Randy Mackay, Jani Hirvinen
Thanks to:	Chris Anderson, Mike Smith, Jordi Munoz, Doug Weibel, James Goppert, Benjamin Pelletier


This firmware is free software; you can redistribute it and/or
modify it under the terms of the GNU Lesser General Public
License as published by the Free Software Foundation; either
version 2.1 of the License, or (at your option) any later version.
*/

////////////////////////////////////////////////////////////////////////////////
// Header includes
////////////////////////////////////////////////////////////////////////////////

// AVR runtime
#include <avr/io.h>
#include <avr/eeprom.h>
#include <avr/pgmspace.h>
#include <math.h>

// Libraries
#include <FastSerial.h>
#include <AP_Common.h>
#include <APM_RC.h>         // ArduPilot Mega RC Library
#include <AP_GPS.h>         // ArduPilot GPS library
#include <Wire.h>			// Arduino I2C lib
#include <DataFlash.h>      // ArduPilot Mega Flash Memory Library
#include <AP_ADC.h>         // ArduPilot Mega Analog to Digital Converter Library
#include <APM_BMP085.h>     // ArduPilot Mega BMP085 Library
#include <AP_Compass.h>     // ArduPilot Mega Magnetometer Library
#include <AP_Math.h>        // ArduPilot Mega Vector/Matrix math Library
#include <AP_IMU.h>         // ArduPilot Mega IMU Library
#include <AP_DCM.h>         // ArduPilot Mega DCM Library
#include <PID.h>            // PID library
#include <RC_Channel.h>     // RC Channel Library
#include <AP_RangeFinder.h>	// Range finder library

#define MAVLINK_COMM_NUM_BUFFERS 2
#include <GCS_MAVLink.h>    // MAVLink GCS definitions

// Configuration
#include "config.h"

// Local modules
#include "defines.h"
#include "Parameters.h"
#include "global_data.h"
#include "GCS.h"
#include "HIL.h"

////////////////////////////////////////////////////////////////////////////////
// Serial ports
////////////////////////////////////////////////////////////////////////////////
//
// Note that FastSerial port buffers are allocated at ::begin time,
// so there is not much of a penalty to defining ports that we don't
// use.
//
FastSerialPort0(Serial);        // FTDI/console
FastSerialPort1(Serial1);       // GPS port
FastSerialPort3(Serial3);       // Telemetry port

////////////////////////////////////////////////////////////////////////////////
// Parameters
////////////////////////////////////////////////////////////////////////////////
//
// Global parameters are all contained within the 'g' class.
//
Parameters      g;

////////////////////////////////////////////////////////////////////////////////
// prototypes
void update_events(void);

////////////////////////////////////////////////////////////////////////////////
// Sensors
////////////////////////////////////////////////////////////////////////////////
//
// There are three basic options related to flight sensor selection.
//
// - Normal flight mode.  Real sensors are used.
// - HIL Attitude mode.  Most sensors are disabled, as the HIL
//   protocol supplies attitude information directly.
// - HIL Sensors mode.  Synthetic sensors are configured that
//   supply data from the simulation.
//

// All GPS access should be through this pointer.
GPS         *g_gps;

#if HIL_MODE == HIL_MODE_NONE

	// real sensors
	AP_ADC_ADS7844          adc;
	APM_BMP085_Class        barometer;
	AP_Compass_HMC5843      compass(Parameters::k_param_compass);

	// real GPS selection
	#if   GPS_PROTOCOL == GPS_PROTOCOL_AUTO
		AP_GPS_Auto     g_gps_driver(&Serial1, &g_gps);

	#elif GPS_PROTOCOL == GPS_PROTOCOL_NMEA
		AP_GPS_NMEA     g_gps_driver(&Serial1);

	#elif GPS_PROTOCOL == GPS_PROTOCOL_SIRF
		AP_GPS_SIRF     g_gps_driver(&Serial1);

	#elif GPS_PROTOCOL == GPS_PROTOCOL_UBLOX
		AP_GPS_UBLOX    g_gps_driver(&Serial1);

	#elif GPS_PROTOCOL == GPS_PROTOCOL_MTK
		AP_GPS_MTK      g_gps_driver(&Serial1);

	#elif GPS_PROTOCOL == GPS_PROTOCOL_MTK16
		AP_GPS_MTK16    g_gps_driver(&Serial1);

	#elif GPS_PROTOCOL == GPS_PROTOCOL_NONE
		AP_GPS_None     g_gps_driver(NULL);

	#else
		#error Unrecognised GPS_PROTOCOL setting.
	#endif // GPS PROTOCOL

#elif HIL_MODE == HIL_MODE_SENSORS
	// sensor emulators
	AP_ADC_HIL              adc;
	APM_BMP085_HIL_Class    barometer;
	AP_Compass_HIL          compass;
	AP_GPS_HIL              g_gps_driver(NULL);

#elif HIL_MODE == HIL_MODE_ATTITUDE
	AP_DCM_HIL              dcm;
	AP_GPS_HIL              g_gps_driver(NULL);
	AP_Compass_HIL          compass; // never used
	AP_IMU_Shim             imu; // never used

#else
	#error Unrecognised HIL_MODE setting.
#endif // HIL MODE

// HIL
#if HIL_MODE != HIL_MODE_DISABLED
	#if HIL_PROTOCOL == HIL_PROTOCOL_MAVLINK
		GCS_MAVLINK hil;
	#elif HIL_PROTOCOL == HIL_PROTOCOL_XPLANE
		HIL_XPLANE hil;
	#endif // HIL PROTOCOL
#endif // HIL_MODE

#if HIL_MODE != HIL_MODE_ATTITUDE
	#if HIL_MODE != HIL_MODE_SENSORS
		// Normal
		AP_IMU_Oilpan imu(&adc, Parameters::k_param_IMU_calibration);
	#else
		// hil imu
		AP_IMU_Shim imu;
	#endif
	// normal dcm
	AP_DCM  dcm(&imu, g_gps);
#endif

////////////////////////////////////////////////////////////////////////////////
// GCS selection
////////////////////////////////////////////////////////////////////////////////
//
#if   GCS_PROTOCOL == GCS_PROTOCOL_MAVLINK
	GCS_MAVLINK         gcs;
#else
	// If we are not using a GCS, we need a stub that does nothing.
	GCS_Class           gcs;
#endif

AP_RangeFinder_MaxsonarXL sonar;

////////////////////////////////////////////////////////////////////////////////
// Global variables
////////////////////////////////////////////////////////////////////////////////

byte 	control_mode		= STABILIZE;
byte 	oldSwitchPosition;					// for remembering the control mode switch

const char *comma = ",";

const char* flight_mode_strings[] = {
	"STABILIZE",
	"ACRO",
	"ALT_HOLD",
	"SIMPLE",
	"FBW",
	"AUTO",
	"GCS_AUTO",
	"LOITER",
	"RTL"};

/* Radio values
		Channel assignments
			1	Ailerons (rudder if no ailerons)
			2	Elevator
			3	Throttle
			4	Rudder (if we have ailerons)
			5	Mode - 3 position switch
			6 	User assignable
			7	trainer switch - sets throttle nominal (toggle switch), sets accels to Level (hold > 1 second)
			8	TBD
*/

// Radio
// -----
int motor_out[8];
Vector3f omega;

// Failsafe
// --------
boolean 	failsafe;						// did our throttle dip below the failsafe value?
boolean 	ch3_failsafe;
boolean		motor_armed;
boolean		motor_auto_safe;

// PIDs
// ----
int 	max_stabilize_dampener;				//
int 	max_yaw_dampener;					//
boolean rate_yaw_flag;						// used to transition yaw control from Rate control to Yaw hold

// LED output
// ----------
boolean motor_light;						// status of the Motor safety
boolean GPS_light;							// status of the GPS light

// GPS variables
// -------------
const 	float t7			= 10000000.0;	// used to scale GPS values for EEPROM storage
float 	scaleLongUp			= 1;			// used to reverse longtitude scaling
float 	scaleLongDown 		= 1;			// used to reverse longtitude scaling
byte 	ground_start_count	= 5;			// have we achieved first lock and set Home?

// Location & Navigation
// ---------------------
const	float radius_of_earth 	= 6378100;	// meters
const	float gravity 			= 9.81;		// meters/ sec^2
long	nav_bearing;						// deg * 100 : 0 to 360 current desired bearing to navigate
long	target_bearing;						// deg * 100 : 0 to 360 location of the plane to the target
long	crosstrack_bearing;					// deg * 100 : 0 to 360 desired angle of plane to target
int		climb_rate;							// m/s * 100  - For future implementation of controlled ascent/descent by rate
float	nav_gain_scaler 		= 1;		// Gain scaling for headwind/tailwind TODO: why does this variable need to be initialized to 1?

byte	command_must_index;					// current command memory location
byte	command_may_index;					// current command memory location
byte	command_must_ID;					// current command ID
byte	command_may_ID;						// current command ID

float cos_roll_x 	= 1;
float cos_pitch_x 	= 1;
float cos_yaw_x 	= 1;
float sin_pitch_y, sin_yaw_y, sin_roll_y;
float sin_nav_y, cos_nav_x;					// used in calc_waypoint_nav
long initial_simple_bearing;				// used for Simple mode

// Airspeed
// --------
int		airspeed;							// m/s * 100

// Location Errors
// ---------------
long	bearing_error;						// deg * 100 : 0 to 36000
long	altitude_error;						// meters * 100 we are off in altitude
float	crosstrack_error;					// meters we are off trackline
long 	distance_error;						// distance to the WP
long 	yaw_error;							// how off are we pointed
long	long_error, lat_error;				// temp for debugging

// Battery Sensors
// ---------------
float	battery_voltage		= LOW_VOLTAGE * 1.05;		// Battery Voltage of total battery, initialized above threshold for filter
float 	battery_voltage1 	= LOW_VOLTAGE * 1.05;		// Battery Voltage of cell 1, initialized above threshold for filter
float 	battery_voltage2 	= LOW_VOLTAGE * 1.05;		// Battery Voltage of cells 1 + 2, initialized above threshold for filter
float 	battery_voltage3 	= LOW_VOLTAGE * 1.05;		// Battery Voltage of cells 1 + 2+3, initialized above threshold for filter
float 	battery_voltage4 	= LOW_VOLTAGE * 1.05;		// Battery Voltage of cells 1 + 2+3 + 4, initialized above threshold for filter

float 	current_voltage 	= LOW_VOLTAGE * 1.05;		// Battery Voltage of cells 1 + 2+3 + 4, initialized above threshold for filter
float	current_amps;
float	current_total;

// Airspeed Sensors
// ----------------

// Barometer Sensor variables
// --------------------------
unsigned long 	abs_pressure;
unsigned long 	ground_pressure;
int 			ground_temperature;

// Altitude Sensor variables
// ----------------------
long	sonar_alt;
long	baro_alt;
byte 	altitude_sensor = BARO;				// used to know which sensor is active, BARO or SONAR

// flight mode specific
// --------------------
boolean	takeoff_complete;					// Flag for using take-off controls
boolean	land_complete;
//int		takeoff_altitude;
int		landing_distance;					// meters;
long 	old_alt;							// used for managing altitude rates
int		velocity_land;
bool 	nav_yaw_towards_wp;					// point at the next WP

// Loiter management
// -----------------
long 	old_target_bearing;					// deg * 100
int		loiter_total; 						// deg : how many times to loiter * 360
int 	loiter_delta;						// deg : how far we just turned
int		loiter_sum;							// deg : how far we have turned around a waypoint
long 	loiter_time;						// millis : when we started LOITER mode
int 	loiter_time_max;					// millis : how long to stay in LOITER mode

// these are the values for navigation control functions
// ----------------------------------------------------
long	nav_roll;							// deg * 100 : target roll angle
long	nav_pitch;							// deg * 100 : target pitch angle
long	nav_yaw;							// deg * 100 : target yaw angle
long	nav_lat;							// for error calcs
long	nav_lon;							// for error calcs
int		nav_throttle;						// 0-1000 for throttle control
int		nav_throttle_old;					// for filtering

long 	command_yaw_start;					// what angle were we to begin with
long 	command_yaw_start_time;				// when did we start turning
int		command_yaw_time;					// how long we are turning
long 	command_yaw_end;					// what angle are we trying to be
long 	command_yaw_delta;					// how many degrees will we turn
int		command_yaw_speed;					// how fast to turn
byte	command_yaw_dir;

// Waypoints
// ---------
long	wp_distance;						// meters - distance between plane and next waypoint
long	wp_totalDistance;					// meters - distance between old and next waypoint
byte	next_wp_index;						// Current active command index

// repeating event control
// -----------------------
byte 	event_id; 							// what to do - see defines
long 	event_timer; 						// when the event was asked for in ms
int 	event_delay; 						// how long to delay the next firing of event in millis
int 	event_repeat;						// how many times to fire : 0 = forever, 1 = do once, 2 = do twice
int 	event_value; 						// per command value, such as PWM for servos
int 	event_undo_value;					// the value used to undo commands
byte 	repeat_forever;
byte 	undo_event;							// counter for timing the undo

// delay command
// --------------
long 	condition_value;					// used in condition commands (eg delay, change alt, etc.)
long 	condition_start;
int 	condition_rate;

// 3D Location vectors
// -------------------
struct 	Location home;						// home location
struct 	Location prev_WP;					// last waypoint
struct 	Location current_loc;				// current location
struct 	Location next_WP;					// next waypoint
struct 	Location tell_command;				// command for telemetry
struct 	Location next_command;				// command preloaded
long 	target_altitude;					// used for
//long 	offset_altitude;					// used for
boolean	home_is_set; 						// Flag for if we have g_gps lock and have set the home location


// IMU variables
// -------------
float G_Dt						= 0.02;		// Integration time for the gyros (DCM algorithm)


// Performance monitoring
// ----------------------
long 	perf_mon_timer;
float 	imu_health; 						// Metric based on accel gain deweighting
int 	G_Dt_max;							// Max main loop cycle time in milliseconds
byte 	gyro_sat_count;
byte 	adc_constraints;
byte 	renorm_sqrt_count;
byte 	renorm_blowup_count;
int 	gps_fix_count;
byte	gcs_messages_sent;


// GCS
// ---
char GCS_buffer[53];
char display_PID = -1;						// Flag used by DebugTerminal to indicate that the next PID calculation with this index should be displayed

// System Timers
// --------------
unsigned long 	fast_loopTimer;				// Time in miliseconds of main control loop
unsigned long 	fast_loopTimeStamp;			// Time Stamp when fast loop was complete
uint8_t 		delta_ms_fast_loop; 		// Delta Time in miliseconds
int 			mainLoop_count;

unsigned long 	medium_loopTimer;			// Time in miliseconds of navigation control loop
byte 			medium_loopCounter;			// Counters for branching from main control loop to slower loops
uint8_t			delta_ms_medium_loop;

byte 			slow_loopCounter;
int 			superslow_loopCounter;
byte			fbw_timer;					// for limiting the execution of FBW input

//unsigned long 	nav_loopTimer;				// used to track the elapsed ime for GPS nav
unsigned long 	nav2_loopTimer;				// used to track the elapsed ime for GPS nav

//unsigned long 	dTnav;						// Delta Time in milliseconds for navigation computations
unsigned long 	dTnav2;						// Delta Time in milliseconds for navigation computations
unsigned long 	elapsedTime;				// for doing custom events
float 			load;						// % MCU cycles used

byte			counter_one_herz;

byte			GPS_failure_counter = 3;
bool			GPS_disabled 		= false;

////////////////////////////////////////////////////////////////////////////////
// Top-level logic
////////////////////////////////////////////////////////////////////////////////

void setup() {
	init_ardupilot();
}

void loop()
{
	// We want this to execute at 100Hz
	// --------------------------------
	if (millis() - fast_loopTimer > 9) {
		delta_ms_fast_loop 	= millis() - fast_loopTimer;
		fast_loopTimer		= millis();
		load				= float(fast_loopTimeStamp - fast_loopTimer) / delta_ms_fast_loop;
		G_Dt 				= (float)delta_ms_fast_loop / 1000.f;		// used by DCM integrator
		mainLoop_count++;

		// Execute the fast loop
		// ---------------------
		fast_loop();
		fast_loopTimeStamp = millis();
	}

	if (millis() - medium_loopTimer > 19) {
		delta_ms_medium_loop 	= millis() - medium_loopTimer;
		medium_loopTimer		= millis();

		medium_loop();

		counter_one_herz++;
		if(counter_one_herz == 50){
			super_slow_loop();
		}

		if (millis() - perf_mon_timer > 20000) {
			if (mainLoop_count != 0) {
				gcs.send_message(MSG_PERF_REPORT);
				if (g.log_bitmask & MASK_LOG_PM)
					Log_Write_Performance();

                resetPerfData();
            }
        }
	}
}

// Main loop 50-100Hz
void fast_loop()
{
	// IMU DCM Algorithm
	read_AHRS();

	// This is the fast loop - we want it to execute at >= 100Hz
	// ---------------------------------------------------------
	if (delta_ms_fast_loop > G_Dt_max)
		G_Dt_max = delta_ms_fast_loop;

	// custom code/exceptions for flight modes
	// ---------------------------------------
	update_current_flight_mode();

	// write out the servo PWM values
	// ------------------------------
	set_servos_4();

#if HIL_PROTOCOL == HIL_PROTOCOL_MAVLINK
	// HIL for a copter needs very fast update of the servo values
	gcs.send_message(MSG_RADIO_OUT);
#endif
}

void medium_loop()
{
	// Read radio
	// ----------
	read_radio();			// read the radio first

	// reads all of the necessary trig functions for cameras, throttle, etc.
	update_trig();

	// This is the start of the medium (10 Hz) loop pieces
	// -----------------------------------------
	switch(medium_loopCounter) {

		// This case deals with the GPS and Compass
		//-----------------------------------------
		case 0:
			medium_loopCounter++;

			if(GPS_failure_counter > 0){
				update_GPS();

			}else if(GPS_failure_counter == 0){
				GPS_disabled = true;
			}
			//readCommands();

			if(g.compass_enabled){
				compass.read();		 						// Read magnetometer
				compass.calculate(dcm.roll, dcm.pitch);		// Calculate heading
				compass.null_offsets(dcm.get_dcm_matrix());
			}

			break;

		// This case performs some navigation computations
		//------------------------------------------------
		case 1:
			medium_loopCounter++;

			// calc pitch and roll to target
			// -----------------------------
			dTnav2 				= millis() - nav2_loopTimer;
			nav2_loopTimer 		= millis();

			// hack to stop navigation in Simple mode
			if (control_mode == SIMPLE)
				break;

			if (control_mode == FBW)
				break;

			// Auto control modes:
			if(g_gps->new_data){
				g_gps->new_data 	= false;

				// we are not tracking I term on navigation, so this isn't needed
				//dTnav 				= millis() - nav_loopTimer;
				//nav_loopTimer 		= millis();

				// calculate the copter's desired bearing and WP distance
				// ------------------------------------------------------
				navigate();
			}

			// we call these regardless of GPS because of the rapid nature of the yaw sensor
			// -----------------------------------------------------------------------------
			if(wp_distance < 800){ // 8 meters
				calc_loiter_nav();
			}else{
				calc_waypoint_nav();
			}

			break;

		// command processing
		//-------------------
		case 2:
			medium_loopCounter++;

			// Read altitude from sensors
			// --------------------------
			update_alt();

			// perform next command
			// --------------------
			if(control_mode == AUTO || control_mode == GCS_AUTO){
				update_commands();
			}
			break;

		// This case deals with sending high rate telemetry
		//-------------------------------------------------
		case 3:
			medium_loopCounter++;

			if (g.log_bitmask & MASK_LOG_ATTITUDE_MED && (g.log_bitmask & MASK_LOG_ATTITUDE_FAST == 0))
				Log_Write_Attitude((int)dcm.roll_sensor, (int)dcm.pitch_sensor, (int)dcm.yaw_sensor);

			#if HIL_MODE != HIL_MODE_ATTITUDE
			if (g.log_bitmask & MASK_LOG_CTUN)
				Log_Write_Control_Tuning();
			#endif

			if (g.log_bitmask & MASK_LOG_NTUN)
				Log_Write_Nav_Tuning();

			if (g.log_bitmask & MASK_LOG_GPS){
				if(home_is_set){
					Log_Write_GPS(g_gps->time,
						current_loc.lat,
						current_loc.lng,
						g_gps->altitude,
						current_loc.alt,
						(long)g_gps->ground_speed,
						g_gps->ground_course,
						g_gps->fix,
						g_gps->num_sats);
				}
			}

            gcs.send_message(MSG_ATTITUDE);     // Sends attitude data
			break;

		// This case controls the slow loop
		//---------------------------------
		case 4:
			medium_loopCounter = 0;

			if (g.current_enabled){
				read_current();
			}

			// Accel trims 		= hold > 2 seconds
			// Throttle cruise  = switch less than 1 second
			// --------------------------------------------
			read_trim_switch();

			// Check for engine arming
			// -----------------------
			arm_motors();

			slow_loop();
			break;

		default:
			// this is just a catch all
			// ------------------------
			medium_loopCounter = 0;
			break;
	}

	// stuff that happens at 50 hz
	// ---------------------------

	// use Yaw to find our bearing error
	calc_bearing_error();

	// guess how close we are - fixed observer calc
	//calc_distance_error();

	if (g.log_bitmask & MASK_LOG_ATTITUDE_FAST)
		Log_Write_Attitude((int)dcm.roll_sensor, (int)dcm.pitch_sensor, (int)dcm.yaw_sensor);

	#if HIL_MODE != HIL_MODE_ATTITUDE
		if (g.log_bitmask & MASK_LOG_RAW)
			Log_Write_Raw();
	#endif

	#if GCS_PROTOCOL == 6		// This is here for Benjamin Pelletier.	Please do not remove without checking with me.	Doug W
		readgcsinput();
	#endif

	#if ENABLE_CAM
		camera_stabilization();
	#endif

    // kick the GCS to process uplink data
    gcs.update();
}

void slow_loop()
{
	// This is the slow (3 1/3 Hz) loop pieces
	//----------------------------------------
	switch (slow_loopCounter){
		case 0:
			slow_loopCounter++;
			superslow_loopCounter++;

			if(superslow_loopCounter > 1400){ // every 7 minutes
				#if HIL_MODE != HIL_MODE_ATTITUDE
					if(g.rc_3.control_in == 0 && g.compass_enabled){
						compass.save_offsets();
						superslow_loopCounter = 0;
					}
				#endif
            }
			break;

		case 1:
			slow_loopCounter++;

			// Read 3-position switch on radio
			// -------------------------------
			read_control_switch();

			// Read main battery voltage if hooked up - does not read the 5v from radio
			// ------------------------------------------------------------------------
			#if BATTERY_EVENT == 1
				read_battery();
			#endif

			break;

		case 2:
			slow_loopCounter = 0;
			update_events();

			// blink if we are armed
			update_motor_light();

			// XXX this should be a "GCS slow loop" interface
			#if GCS_PROTOCOL == GCS_PROTOCOL_MAVLINK
				gcs.data_stream_send(1,5);
				// send all requested output streams with rates requested
				// between 1 and 5 Hz
			#else
				gcs.send_message(MSG_LOCATION);
			#endif


			break;

		default:
			slow_loopCounter = 0;
			break;

	}
}

// 1Hz loop
void super_slow_loop()
{
	if (g.log_bitmask & MASK_LOG_CUR)
		Log_Write_Current();

    gcs.send_message(MSG_HEARTBEAT); // XXX This is running at 3 1/3 Hz instead of 1 Hz
	// gcs.send_message(MSG_CPU_LOAD, load*100);

}

void update_GPS(void)
{
	g_gps->update();
	update_GPS_light();

    if (g_gps->new_data && g_gps->fix) {
    	GPS_failure_counter = 3;

		// XXX We should be sending GPS data off one of the regular loops so that we send
		// no-GPS-fix data too
		#if GCS_PROTOCOL != GCS_PROTOCOL_MAVLINK
			gcs.send_message(MSG_LOCATION);
		#endif

		// for performance
		// ---------------
		gps_fix_count++;

		if(ground_start_count > 1){
			ground_start_count--;

		} else if (ground_start_count == 1) {

			// We countdown N number of good GPS fixes
			// so that the altitude is more accurate
			// -------------------------------------
			if (current_loc.lat == 0) {
                SendDebugln("!! bad loc");
				ground_start_count = 5;

			}else{
				//Serial.printf("init Home!");

				if (g.log_bitmask & MASK_LOG_CMD)
					Log_Write_Startup(TYPE_GROUNDSTART_MSG);

				// reset our nav loop timer
				//nav_loopTimer = millis();
				init_home();

				// init altitude
				current_loc.alt = g_gps->altitude;
				ground_start_count = 0;
			}
		}

		current_loc.lng = g_gps->longitude;	// Lon * 10 * *7
		current_loc.lat = g_gps->latitude;		// Lat * 10 * *7

	}else{
		if(GPS_failure_counter > 0)
			GPS_failure_counter--;
	}
}

void update_current_flight_mode(void)
{
	if(control_mode == AUTO){

		switch(command_must_ID){
			//case MAV_CMD_NAV_TAKEOFF:
			//	break;

			//case MAV_CMD_NAV_LAND:
			//	break;

			default:
				// Output Pitch, Roll, Yaw and Throttle
				// ------------------------------------
				auto_yaw();

				// mix in user control
				control_nav_mixer();

				// perform stabilzation
				output_stabilize_roll();
				output_stabilize_pitch();

				// apply throttle control
				output_auto_throttle();
				break;
		}

	}else{

		switch(control_mode){
			case ACRO:
				// clear any AP naviagtion values
				nav_pitch 		= 0;
				nav_roll 		= 0;

				// Output Pitch, Roll, Yaw and Throttle
				// ------------------------------------

				// Yaw control
				output_manual_yaw();

				// apply throttle control
				output_manual_throttle();

				// mix in user control
				control_nav_mixer();

				// perform rate or stabilzation
				// ----------------------------

				// Roll control
				if(abs(g.rc_1.control_in) >= ACRO_RATE_TRIGGER){
					output_rate_roll(); // rate control yaw
				}else{
					output_stabilize_roll(); // hold yaw
				}

				// Roll control
				if(abs(g.rc_2.control_in) >= ACRO_RATE_TRIGGER){
					output_rate_pitch(); // rate control yaw
				}else{
					output_stabilize_pitch(); // hold yaw
				}
				break;

			//case LOITER:
			case STABILIZE:
				// clear any AP naviagtion values
				nav_pitch 		= 0;
				nav_roll 		= 0;

				// Output Pitch, Roll, Yaw and Throttle
				// ------------------------------------

				// Yaw control
				output_manual_yaw();

				// apply throttle control
				output_manual_throttle();

				// mix in user control
				control_nav_mixer();

				// perform stabilzation
				output_stabilize_roll();
				output_stabilize_pitch();
				break;

			case SIMPLE:
				fbw_timer++;
				// 25 hz
				if(fbw_timer > 4){
					fbw_timer = 0;

					current_loc.lat = 0;
					current_loc.lng = 0;

					next_WP.lng =   (float)g.rc_1.control_in *.4;  // X: 4500 / 2 = 2250 = 25 meteres
					next_WP.lat = -((float)g.rc_2.control_in *.4); // Y: 4500 / 2 = 2250 = 25 meteres

					// calc a new bearing
					nav_bearing 	= get_bearing(&current_loc, &next_WP) + initial_simple_bearing;
					nav_bearing 	= wrap_360(nav_bearing);
					wp_distance 	= get_distance(&current_loc, &next_WP);
					calc_bearing_error();
					/*
					Serial.printf("lat: %ld lon:%ld, bear:%ld, dist:%ld, init:%ld, err:%ld ",
							next_WP.lat,
							next_WP.lng,
							nav_bearing,
							wp_distance,
							initial_simple_bearing,
							bearing_error);
					*/
					// get nav_pitch and nav_roll
					calc_waypoint_nav();
				}

				// Output Pitch, Roll, Yaw and Throttle
				// ------------------------------------
				// Yaw control
				output_manual_yaw();

				// apply throttle control
				output_manual_throttle();

				// apply nav_pitch and nav_roll to output
				fbw_nav_mixer();

				// perform stabilzation
				output_stabilize_roll();
				output_stabilize_pitch();
			break;

			case FBW:
				// we are currently using manual throttle during alpha testing.
				fbw_timer++;

				// 10 hz
				if(fbw_timer > 10){
					fbw_timer = 0;

					if(GPS_disabled){
						current_loc.lat = home.lat = 0;
						current_loc.lng = home.lng = 0;
					}

					next_WP.lng = home.lng + g.rc_1.control_in / 2; // X: 4500 / 2 = 2250 = 25 meteres
					next_WP.lat = home.lat - g.rc_2.control_in / 2; // Y: 4500 / 2 = 2250 = 25 meteres

					calc_loiter_nav();
				}

				// Output Pitch, Roll, Yaw and Throttle
				// ------------------------------------

				// REMOVE AFTER TESTING !!!
				//nav_yaw = dcm.yaw_sensor;

				// Yaw control
				output_manual_yaw();

				// apply throttle control
				output_manual_throttle();

				// apply nav_pitch and nav_roll to output
				fbw_nav_mixer();

				// perform stabilzation
				output_stabilize_roll();
				output_stabilize_pitch();
				break;

			case ALT_HOLD:
				// clear any AP naviagtion values
				nav_pitch 		= 0;
				nav_roll 		= 0;

				//if(g.rc_3.control_in)
				// get desired height from the throttle
				next_WP.alt 	= home.alt + (g.rc_3.control_in); // 0 - 1000 (40 meters)
				next_WP.alt		= max(next_WP.alt, 30);

				// !!! testing
				//next_WP.alt 	-= 500;

				// Yaw control
				// -----------
				output_manual_yaw();

				// Output Pitch, Roll, Yaw and Throttle
				// ------------------------------------
				// apply throttle control
				output_auto_throttle();

				// mix in user control
				control_nav_mixer();

				// perform stabilzation
				output_stabilize_roll();
				output_stabilize_pitch();
				break;

			case RTL:
				// Output Pitch, Roll, Yaw and Throttle
				// ------------------------------------
				auto_yaw();

				// apply throttle control
				output_auto_throttle();

				// mix in user control with Nav control
				control_nav_mixer();

				// perform stabilzation
				output_stabilize_roll();
				output_stabilize_pitch();
				break;

			case LOITER:

				// Yaw control
				// -----------
				output_manual_yaw();

				// Output Pitch, Roll, Yaw and Throttle
				// ------------------------------------

				// apply throttle control
				output_auto_throttle();

				// mix in user control with Nav control
				control_nav_mixer();

				// perform stabilzation
				output_stabilize_roll();
				output_stabilize_pitch();
				break;

			default:
				//Serial.print("$");
				break;

		}
	}
}

// called after a GPS read
void update_navigation()
{
	// wp_distance is in ACTUAL meters, not the *100 meters we get from the GPS
	// ------------------------------------------------------------------------

	// distance and bearing calcs only
	if(control_mode == AUTO || control_mode == GCS_AUTO){
		verify_commands();

	}else{
		switch(control_mode){
			case RTL:
				update_crosstrack();
				break;
		}
	}
}


void read_AHRS(void)
{
	// Perform IMU calculations and get attitude info
	//-----------------------------------------------
	dcm.update_DCM(G_Dt);
	omega = dcm.get_gyro();

	// Testing remove !!!
	//dcm.pitch_sensor = 0;
	//dcm.roll_sensor = 0;
}

void update_trig(void){
	Vector2f yawvector;
	Matrix3f temp 	= dcm.get_dcm_matrix();

	yawvector.x 	= temp.a.x; // sin
	yawvector.y 	= temp.b.x;	// cos
	yawvector.normalize();

	cos_yaw_x 		= yawvector.y;	// 0 x = north
	sin_yaw_y 		= yawvector.x;	// 1 y

	sin_pitch_y 	= -temp.c.x;
	cos_pitch_x 	= sqrt(1 - (temp.c.x * temp.c.x));

	cos_roll_x 		= temp.c.z / cos_pitch_x;
	sin_roll_y 		= temp.c.y / cos_pitch_x;
}


void update_alt()
{
#if HIL_MODE == HIL_MODE_ATTITUDE
	current_loc.alt = g_gps->altitude;
#else
	altitude_sensor = BARO;
	baro_alt 		= read_barometer();
	//Serial.printf("b_alt: %ld, home: %ld ", baro_alt, home.alt);

	if(g.sonar_enabled){
		// decide which sensor we're usings
		sonar_alt 		= sonar.read();

		if(baro_alt < 550){
			altitude_sensor = SONAR;
		}

		if(sonar_alt > 600){
			altitude_sensor = BARO;
		}

		//altitude_sensor = (target_altitude > (home.alt + 500)) ? BARO : SONAR;

		if(altitude_sensor == BARO){
			current_loc.alt = baro_alt + home.alt;
		}else{
			sonar_alt		= min(sonar_alt, 600);
			current_loc.alt = sonar_alt + home.alt;
		}

	}else{

		// no sonar altitude
		current_loc.alt = baro_alt + home.alt;
	}
	//Serial.printf("b_alt: %ld, home: %ld ", baro_alt, home.alt);
#endif

	// altitude smoothing
	// ------------------
	calc_altitude_smoothing_error();


	//calc_altitude_error();

	// Amount of throttle to apply for hovering
	// ----------------------------------------
	calc_nav_throttle();
}
