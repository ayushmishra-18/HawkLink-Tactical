# **🦅 HawkLink Tactical System**



A secure, offline-first Command \& Control (C2) platform for tactical situational awareness.



HawkLink allows commanders to coordinate field units in real-time without relying on the internet or cellular infrastructure. It uses a secure local TCP mesh to transmit GPS, orders, and intelligence data.



## **📡 System Interface**



This repository contains two independent yet interconnected applications:



### **🖥️ Commander Console (Desktop)**



The tactical "God View" (C2 (Command \& Control) dashboard for strategic oversight) running on Windows. Features 3D satellite terrain, unit tracking, and waypoint management.





Screenshot:-



Command\_Console :- [Command](commander_console/assets/screenshots/commander_console.png)



### **📱 Soldier Uplink (Mobile)**



The field operative's view. Features GPS tracking, SOS beacon, stealth mode, image intel, AR cam, and secure comms.



Screenshot:-



Soldier:- [Alpha-1](hawklink_client/assets/screenshots/alpha-1.jpg)  [Bravo-1](hawklink_client/assets/screenshots/BRAVO-1.jpg)  [Delta-1](hawklink_client/assets/screenshots/DELTA-1.jpg)







### **✨ Key Features**



#### **📡 1. Secure Offline Communication**



* Zero-Internet Dependency: Works entirely over local LAN, Hotspot, or Mesh VPN (Tailscale).



* AES-256 Encryption: All packets (chat, GPS, images, bio-data) are encrypted before transmission.



* Custom TCP Protocol: Binary-efficient data exchange for low-latency performance.





#### **🖥️ 2. Commander Console View (Desktop)**



* 3D Satellite Map: Tilt and rotate the battlefield for tactical terrain analysis.



* Live Bio-Telemetry Platform: Real-time visualization of soldier status:



 	EKG Graph: Live animating heart rate monitor.



 	SpO2 \& Battery: Critical vital stats at a glance.



* Real-Time Unit Tracking: Live position updates with Breadcrumb Trails.



* Tactical Waypoints: Drop drag-and-drop markers:



 	🏁 Rally Point

 	💀 Enemy Contact

 	🏥 Medical Cache

 	🚁 Landing Zone (LZ)



* Dynamic Geofencing: Draw "Red Zones" on the map; soldiers inside receive immediate audio/visual warnings.



* Intel Hub: Receives and displays encrypted images from field units.



* Persistent Logs: Automatically saves chat history and intel to disk.



#### **📱 Soldier Uplink View (Mobile)**



* Role-Based Warfare: Select classes (Medic, Sniper, Scout, Engineer) with unique icons.



* AR Compass (Augmented Reality): Heads-Up Display (HUD) overlaying waypoints and distances on the real-world camera feed.



* Compass Vision: Transmits real-time magnetic heading (Cone of Vision) to the commander.



* Optical Bio-Scanner: Uses the phone's camera and flash \[PPG (Photoplethysmography) technology to measure Heart Rate without external hardware.



* Acoustic Gunshot Detection: Passive microphone monitoring that automatically detects high-decibel spikes (>95dB) and sends a "CONTACT REPORT" to Command.



* Tactical Cam: Snap and send encrypted photos directly to HQ.



* Stealth Mode: One-tap toggle to switch UI to OLED Black/Red for night vision compatibility.



* Voice Command (TTS): Reads orders out loud ("New Order: Move to Sector 4").



* SOS Beacon: Emergency panic button that triggers a fleet-wide alert.



* Order Acknowledgment: "COPY THAT" button to confirm receipt of orders.



#### **🚀 Getting Started**



##### **🔧 Prerequisites**



###### 

* ###### Flutter SDK(3.0+)
* ###### Visual Studio (required for Windows desktop builds)
* ###### Android Studio (required for mobile builds)





##### **▶️ 1. Installation**



###### Clone the repository:



```

git clone \\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\[https://github.com/ayushmishra-18/HawkLink-Tactical.git](https://github.com/ayushmishra-18/HawkLink-Tactical.git)

cd HawkLink-Tactical

```





##### **▶️ 2.Running the Commander Console(Server)**



###### The Commander Console acts as the server. Run this first on your laptop.



```

cd commander\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\_console



flutter pub get



flutter run -d windows

```



###### 💡 Replace windows with linux or macos depending on your platform.

###### Note the IP address displayed on the left panel (e.g., 192.168.1.5).



##### **▶️ 3.Running the Soldier App(Client)**



###### Run this on an physical Android device(Sensors required)



```

cd soldier\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\_app



flutter pub get



flutter run -d android

```



###### Enter the Commander's IP address and click on Link

#### **🧪 Potential Applications**



* Military \& defense operations



* Disaster response \& rescue missions



* Border patrol \& surveillance



* Remote area coordination



* Emergency services \& law enforcement

###### 

#### **🛠️ Tech Stack**



* Framework: Flutter (Dart)



* Maps: flutter\_map + latlong2 (ArcGIS Satellite Tiles)



* Networking: Raw TCP Sockets (dart:io)



* State Management: setState (Optimized for low overhead)



* Security: encrypt (AES-CBC)



* Sensors:

 	geolocator \& flutter\_compass  (Navigation)

 	camera  (AR \& BIO-scanning)
noise\_meter  (Aciustic Detection)

 	battery\_plus(Hardware monitering)



* Audio/Media: audioplayers, flutter\_tts, image\_picker



#### **🛡️ Project Focus**



* Offline-first communication



* Secure TCP-based data exchange



* Tactical visualization \& command acknowledgment



* Designed for defense, emergency response, and disaster operations



#### **🏆 Why HawkLink Stands Out**



* ❌ No internet dependency



* 🔁 Two-way acknowledgment-based communication



* 🗺️ Map-driven situational awareness



* 📡 Designed for RF / mesh expansion



* ⚔️ Replaces error-prone voice radio commands



#### **📜 Note**



This project is developed for educational, research, and hackathon demonstration purposes.

## 📄 License

###### 

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

###### 

#### ⚠️ Disclaimer

###### 

This software is a PROTOTYPE intended for educational and simulation purposes only.



Not MilSpec: This application utilizes standard WiFi/TCP protocols and simulated encryption. It is not certified for real-world combat operations or classified communication.



No Warranty: As per the MIT License, the software is provided "as is", without warranty of any kind. The developers are not liable for any damages or tactical failures arising from the use of this software.

