package com.example.omkar

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.widget.Toast

import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

import androidx.core.content.ContextCompat

import com.example.omkar.ui.theme.OmkarTheme


class MainActivity : ComponentActivity() {

    private lateinit var notificationHelper: NotificationHelper

    private val requestPermissionLauncher =
        registerForActivityResult(
            ActivityResultContracts.RequestMultiplePermissions()
        ) { permissions ->

            val receiveGranted =
                permissions[Manifest.permission.RECEIVE_SMS] ?: false

            val readGranted =
                permissions[Manifest.permission.READ_SMS] ?: false

            if (receiveGranted && readGranted) {

                Toast.makeText(
                    this,
                    "SMS permissions granted",
                    Toast.LENGTH_SHORT
                ).show()

            } else {

                Toast.makeText(
                    this,
                    "SMS permissions denied",
                    Toast.LENGTH_LONG
                ).show()
            }
        }


    private val notificationPermissionLauncher =
        registerForActivityResult(
            ActivityResultContracts.RequestPermission()
        ) { granted ->

            if (granted) {

                Toast.makeText(
                    this,
                    "Notification permission granted",
                    Toast.LENGTH_SHORT
                ).show()

            } else {

                Toast.makeText(
                    this,
                    "Notification permission denied",
                    Toast.LENGTH_LONG
                ).show()
            }
        }


    override fun onCreate(savedInstanceState: Bundle?) {

        super.onCreate(savedInstanceState)

        enableEdgeToEdge()

        notificationHelper =
            NotificationHelper(this)

        requestSmsPermissions()

        requestNotificationPermission()

        setContent {

            OmkarTheme {

                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background
                ) {

                    MainScreen(

                        onScanQR = {

                            val intent =
                                Intent(
                                    this,
                                    QRScannerActivity::class.java
                                )

                            startActivity(intent)
                        },

                        onTestNotification = {

                            notificationHelper.showScamAlert(
                                riskLevel = "HIGH",
                                reason = "Suspicious keyword detected in SMS"
                            )
                        }
                    )
                }
            }
        }
    }


    private fun requestNotificationPermission() {

        if (
            android.os.Build.VERSION.SDK_INT >=
            android.os.Build.VERSION_CODES.TIRAMISU
        ) {

            if (
                ContextCompat.checkSelfPermission(
                    this,
                    Manifest.permission.POST_NOTIFICATIONS
                ) != PackageManager.PERMISSION_GRANTED
            ) {

                notificationPermissionLauncher.launch(
                    Manifest.permission.POST_NOTIFICATIONS
                )
            }
        }
    }


    private fun requestSmsPermissions() {

        val receiveGranted =
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.RECEIVE_SMS
            ) == PackageManager.PERMISSION_GRANTED

        val readGranted =
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.READ_SMS
            ) == PackageManager.PERMISSION_GRANTED

        if (!receiveGranted || !readGranted) {

            requestPermissionLauncher.launch(
                arrayOf(
                    Manifest.permission.RECEIVE_SMS,
                    Manifest.permission.READ_SMS
                )
            )
        }
    }
}


@Composable
fun MainScreen(
    onScanQR: () -> Unit,
    onTestNotification: () -> Unit
) {

    Column(

        modifier = Modifier
            .fillMaxSize()
            .padding(24.dp),

        horizontalAlignment =
            Alignment.CenterHorizontally,

        verticalArrangement =
            Arrangement.Center
    ) {

        Text(
            text = "AI ScamShield",
            style = MaterialTheme.typography.headlineMedium
        )

        Button(
            onClick = onScanQR,
            modifier = Modifier.padding(top = 24.dp)
        ) {

            Text("Scan QR")
        }

        Button(
            onClick = onTestNotification,
            modifier = Modifier.padding(top = 16.dp)
        ) {

            Text("Test Scam Notification")
        }
    }
}
