# **🦅 HawkLink Tactical System**



**HawkLink Tactical System** is a **dual-application tactical situational awareness platform** built with **Flutter**, designed for secure command-to-unit coordination in disconnected or low-infrastructure environments.



## **📡 System Overview**



This repository contains two independent yet interconnected applications:



### 🖥️ **Commander Console (Desktop)**



* ###### Cross-platform support: **Windows / Linux / macOS**

###### 

* ###### Acts as a **TCP Server** for managing connected units

###### 

* ###### **3D Satellite Map** with tactical plotting \& unit visualization

###### 

* ###### Designed for command-level decision making



###### 📁 Location: commander\_console/



### 📱 **Soldier Uplink (Mobile)**



* ###### Cross-platform support: **Android / iOS**

###### 

* ###### Real-time **GPS tracking**

###### 

* ###### **SOS / Emergency Beacon**

###### 

* ###### **Secure TCP uplink** to Commander Console

###### 

* ###### Built for field deployment and low-bandwidth usage



###### 📁 Location: soldier\_app/



# **✨ Key Features**





## **Commander Console**

### 

* ###### 🗺️ Interactive 3D terrain-based map

###### 

* ###### 📍 Live unit tracking

###### 

* ###### 🧭 Tactical command plotting

###### 

* ###### ✅ Command acknowledgment monitoring

### 

## **Soldier Uplink**

### 

* ###### 📡 Real-time GPS updates

###### 

* ###### 🆘 Emergency SOS beacon

###### 

* ###### 🔒 Secure uplink to command

###### 

* ###### 🔋 Battery-efficient background operation









## **📸 System Screenshots**

### 

### **🖥️ Commander Console View (Desktop)**

### 

###### [**Commander Console**](assets/screenshots/commander/commander_console.png)





##### **Commander-side dashboard showing live unit positions, tactical map view, and network activity.**

### 

### **---**

### 

### **📱 Soldier Uplink View (Mobile)**

### 

###### [**Soldier Uplink – Alpha-1**](assets/screenshots/soldier/soldier_1.jpg)



##### **Field unit (ALPHA-1) with secure uplink, live GPS position, and quick-access tactical controls.**

### 

###### [**Soldier Uplink – Alpha-2**](assets/screenshots/soldier/soldier_2.jpg)

### 

##### **Second field unit (ALPHA-2) operating simultaneously under the same command network.**





## **🚀** **Getting Started**



### **🔧 Prerequisites**



#### **Ensure the following tools are installed:**



* ###### Flutter SDK

###### 

* ###### Visual Studio (required for Windows desktop builds)

###### 

* ###### Android Studio (required for mobile builds)

###### 

##### **▶️ Running the Commander Console**



```

cd commander\_console

flutter pub get

flutter run -d windows

```





###### 💡 Replace windows with linux or macos depending on your platform.



##### **▶️** **Running the Soldier App**



```

cd soldier\_app

flutter pub get

flutter run -d android

```





###### 📱 Ensure an Android emulator or physical device is connected.





# 🧪 Potential Applications

### 

* ###### Military \& defense operations

###### 

* ###### Disaster response \& rescue missions

###### 

* ###### Border patrol \& surveillance

###### 

* ###### Remote area coordination

###### 

* ###### Emergency services \& law enforcement









# 🧩 Tech Stack



* ###### Flutter (Desktop + Mobile)

###### 

* ###### TCP Socket Communication

###### 

* ###### 3D Map Visualization

###### 

* ###### Cross-platform deployment









## **🛡️ Project Focus**



* ###### Offline-first communication

###### 

* ###### Secure TCP-based data exchange

###### 

* ###### Tactical visualization \& command acknowledgment

###### 

* ###### Designed for defense, emergency response, and disaster operations







# 🏆 Why HawkLink Stands Out

###### 

* ###### ❌ No internet dependency

###### 

* ###### 🔁 Two-way acknowledgment-based communication

###### 

* ###### 🗺️ Map-driven situational awareness

###### 

* ###### 📡 Designed for RF / mesh expansion

###### 

* ###### ⚔️ Replaces error-prone voice radio commands

###### 

# 📜 Note

###### 

* ###### This project is developed for educational, research, and hackathon demonstration purposes.
