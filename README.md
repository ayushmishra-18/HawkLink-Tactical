# **🦅 HawkLink Tactical System**



A secure, offline-first Command \& Control (C2) platform for tactical situational awareness.



HawkLink allows commanders to coordinate field units in real-time without relying on the internet or cellular infrastructure. It uses a secure local TCP mesh to transmit GPS, orders, and intelligence data.



## **📡 System Interface**



This repository contains two independent yet interconnected applications:



### **🖥️ Commander Console (Desktop)**



The tactical "God View" running on Windows. Features 3D satellite terrain, unit tracking, and waypoint management.





Screenshot:-



Command\_Console :- [Command](commander_console/assets/screenshots/command_console.jpg)



### **📱 Soldier Uplink (Mobile)**



The field operative's view. Features GPS tracking, SOS beacon, stealth mode, and secure comms.



Screenshot:-



Soldier:- [Alpha-1](hawklink_client/assets/screenshots/alpha-1.jpg)





### **✨ Key Features**



#### **📡 Core Architecture**



* Offline-First: Works over Local Wi-Fi, Hotspot, or Mesh VPN (Tailscale). No internet required.



* Secure TCP Mesh: Custom encrypted socket protocol for low-latency data transmission.



* AES-256 Encryption: All data (chat, location, images) is encrypted before transmission.



* Cross-Platform: Commander (Windows/Linux/Mac) + Soldier (Android/iOS).



#### **🖥️ Commander Console View (Desktop)**



* 3D Satellite Map: Tilt and rotate the battlefield for tactical terrain analysis.



* Real-Time Unit Tracking: Live position updates with Breadcrumb Trails.



* Biometric Feed: Monitors soldier heart rate (BPM) and battery levels.



* Tactical Waypoints: Drop drag-and-drop markers:



 	1. 🏁 Rally Point

 	2. 💀 Enemy Contact

 	3. 🏥 Medical Cache

 	4. 🚁 Landing Zone (LZ)



* Geofencing: Draw custom "Red Zones" (Danger Areas). Automatically warns soldiers if they enter.



* Intel Hub: Receives and displays encrypted images from field units.



* Persistent Logs: Automatically saves chat history and intel to disk.



#### **📱 Soldier Uplink View (Mobile)**



* Role-Based Warfare: Select classes (Medic, Sniper, Scout, Engineer) with unique icons.



* Compass Vision: Transmits real-time magnetic heading (Cone of Vision) to the commander.



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

git clone \\\[https://github.com/ayushmishra-18/HawkLink-Tactical.git](https://github.com/ayushmishra-18/HawkLink-Tactical.git)

cd HawkLink-Tactical

```





##### **▶️ 2.Running the Commander Console(Server)**



###### The Commander Console acts as the server. Run this first on your laptop.



```

cd commander\\\\\\\_console



flutter pub get



flutter run -d windows

```



###### 💡 Replace windows with linux or macos depending on your platform.

###### Note the IP address displayed on the left panel (e.g., 192.168.1.5).



##### **▶️ 3.Running the Soldier App(Client)**



###### Run this on an Android device or emulator.



```

cd soldier\\\\\\\_app



flutter pub get



flutter run -d android

```



###### Enter the Commander's IP address and click the Link icon to connect.



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



* Security: encrypt (AES-CBC)



* Sensors: geolocator, flutter\_compass, battery\_plus



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



###### This project is developed for educational, research, and hackathon demonstration purposes.

