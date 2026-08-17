package com.example.omkar

import android.Manifest
import android.content.pm.PackageManager
import android.media.Image
import android.net.Uri
import android.os.Bundle
import android.widget.Toast

import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.annotation.OptIn

import androidx.camera.core.CameraSelector
import androidx.camera.core.ExperimentalGetImage
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView

import androidx.core.content.ContextCompat

import com.example.omkar.ui.theme.OmkarTheme
import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.FirebaseFirestore

import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage

import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean


class QRScannerActivity : ComponentActivity() {

    private val cameraPermissionLauncher =
        registerForActivityResult(
            ActivityResultContracts.RequestPermission()
        ) { granted ->

            if (granted) {
                showScanner()
            } else {
                Toast.makeText(
                    this,
                    "Camera permission is required",
                    Toast.LENGTH_LONG
                ).show()

                finish()
            }
        }


    override fun onCreate(savedInstanceState: Bundle?) {

        super.onCreate(savedInstanceState)

        if (
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.CAMERA
            ) == PackageManager.PERMISSION_GRANTED
        ) {

            showScanner()

        } else {

            cameraPermissionLauncher.launch(
                Manifest.permission.CAMERA
            )
        }
    }


    private fun showScanner() {

        setContent {

            OmkarTheme {

                QRScannerUI(

                    onClose = {
                        finish()
                    },

                    onQrDetected = { qrData ->
                        checkQrData(qrData)
                    }
                )
            }
        }
    }


    // =====================================================
    // CHECK QR CONTENT
    // =====================================================

    private fun checkQrData(qrData: String) {

        val cleanData = qrData.trim()


        // =================================================
        // UPI PAYMENT QR
        // =================================================

        if (
            cleanData.startsWith(
                "upi://pay",
                ignoreCase = true
            )
        ) {

            val upiId = extractUpiId(cleanData)

            if (upiId == null) {

                Toast.makeText(
                    this,
                    "Invalid UPI QR",
                    Toast.LENGTH_LONG
                ).show()

                return
            }

            checkUpiId(upiId)

            return
        }


        // =================================================
        // DIRECT UPI ID
        // Example: test@upi
        // =================================================

        if (
            cleanData.contains("@") &&
            !cleanData.startsWith(
                "http://",
                ignoreCase = true
            ) &&
            !cleanData.startsWith(
                "https://",
                ignoreCase = true
            )
        ) {

            checkUpiId(cleanData)

            return
        }


        // =================================================
        // URL QR
        // =================================================

        if (
            cleanData.startsWith(
                "http://",
                ignoreCase = true
            ) ||
            cleanData.startsWith(
                "https://",
                ignoreCase = true
            )
        ) {

            checkUrl(cleanData)

            return
        }


        // =================================================
        // UNKNOWN QR
        // =================================================

        Toast.makeText(
            this,
            "QR contains unsupported information",
            Toast.LENGTH_LONG
        ).show()
    }


    // =====================================================
    // CHECK UPI ID IN FIRESTORE
    // =====================================================

    private fun checkUpiId(upiId: String) {

        val db =
            FirebaseFirestore.getInstance()


        db.collection("scam_upi")
            .whereEqualTo(
                "upiId",
                upiId
            )
            .limit(1)
            .get()

            .addOnSuccessListener { documents ->

                if (!documents.isEmpty) {

                    val document =
                        documents.documents[0]


                    val riskLevel =
                        document.getString(
                            "riskLevel"
                        ) ?: "Unknown"


                    val reason =
                        document.getString(
                            "reason"
                        ) ?: "No reason available"


                    Toast.makeText(
                        this,
                        "UPI: $upiId\n" +
                                "Risk: $riskLevel\n" +
                                "Reason: $reason",
                        Toast.LENGTH_LONG
                    ).show()


                    // Save scan result
                    saveQrScan(
                        qrData = upiId,
                        type = "UPI",
                        riskLevel = riskLevel,
                        reason = reason
                    )

                } else {

                    val riskLevel =
                        "SAFE"


                    val reason =
                        "No scam record found"


                    Toast.makeText(
                        this,
                        "UPI: $upiId\n" +
                                "Risk: SAFE\n" +
                                "Reason: $reason",
                        Toast.LENGTH_LONG
                    ).show()


                    // Save safe scan
                    saveQrScan(
                        qrData = upiId,
                        type = "UPI",
                        riskLevel = riskLevel,
                        reason = reason
                    )
                }
            }

            .addOnFailureListener { error ->

                Toast.makeText(
                    this,
                    "UPI Firebase check failed:\n" +
                            error.message,
                    Toast.LENGTH_LONG
                ).show()
            }
    }


    // =====================================================
    // CHECK URL IN FIRESTORE
    // =====================================================

    private fun checkUrl(url: String) {

        val uri =
            try {
                Uri.parse(url)
            } catch (e: Exception) {
                null
            }


        if (
            uri == null ||
            uri.host.isNullOrBlank()
        ) {

            Toast.makeText(
                this,
                "Invalid URL detected",
                Toast.LENGTH_LONG
            ).show()

            return
        }


        val host =
            uri.host ?: "Unknown"


        val db =
            FirebaseFirestore.getInstance()


        // Check URL against scam_urls collection
        db.collection("scam_urls")
            .whereEqualTo(
                "url",
                url
            )
            .limit(1)
            .get()

            .addOnSuccessListener { documents ->

                if (!documents.isEmpty) {

                    // -------------------------------------
                    // URL FOUND IN BLACKLIST
                    // -------------------------------------

                    val document =
                        documents.documents[0]


                    val riskLevel =
                        document.getString(
                            "riskLevel"
                        ) ?: "High"


                    val reason =
                        document.getString(
                            "reason"
                        ) ?: "Suspicious URL"


                    Toast.makeText(
                        this,
                        "URL detected\n\n" +
                                "Website: $host\n" +
                                "Risk: $riskLevel\n" +
                                "Reason: $reason",
                        Toast.LENGTH_LONG
                    ).show()


                    saveQrScan(
                        qrData = url,
                        type = "URL",
                        riskLevel = riskLevel,
                        reason = reason,
                        website = host
                    )

                } else {

                    // -------------------------------------
                    // URL NOT FOUND
                    // -------------------------------------

                    val riskLevel =
                        "SAFE"


                    val reason =
                        "No scam URL record found"


                    Toast.makeText(
                        this,
                        "URL detected\n\n" +
                                "Website: $host\n" +
                                "Risk: SAFE\n" +
                                "Reason: $reason",
                        Toast.LENGTH_LONG
                    ).show()


                    saveQrScan(
                        qrData = url,
                        type = "URL",
                        riskLevel = riskLevel,
                        reason = reason,
                        website = host
                    )
                }
            }

            .addOnFailureListener { error ->

                Toast.makeText(
                    this,
                    "URL Firebase check failed:\n" +
                            error.message,
                    Toast.LENGTH_LONG
                ).show()
            }
    }


    // =====================================================
    // SAVE QR SCAN RESULT
    // =====================================================

    private fun saveQrScan(
        qrData: String,
        type: String,
        riskLevel: String,
        reason: String,
        website: String? = null
    ) {

        val db =
            FirebaseFirestore.getInstance()


        val data =
            hashMapOf<String, Any>(

                "qrData" to qrData,

                "type" to type,

                "riskLevel" to riskLevel,

                "reason" to reason,

                "timestamp" to
                        FieldValue.serverTimestamp()
            )


        if (website != null) {

            data["website"] =
                website
        }


        db.collection("qr_scans")
            .add(data)

            .addOnSuccessListener {

                Toast.makeText(
                    this,
                    "QR result saved to Firebase",
                    Toast.LENGTH_SHORT
                ).show()
            }

            .addOnFailureListener { error ->

                Toast.makeText(
                    this,
                    "QR detected but save failed:\n" +
                            error.message,
                    Toast.LENGTH_LONG
                ).show()
            }
    }


    // =====================================================
    // EXTRACT UPI ID
    // =====================================================

    private fun extractUpiId(
        qrData: String
    ): String? {

        return try {

            val uri =
                Uri.parse(qrData)


            val upiId =
                uri.getQueryParameter(
                    "pa"
                )


            if (
                !upiId.isNullOrBlank()
            ) {

                upiId.trim()

            } else {

                null
            }

        } catch (e: Exception) {

            null
        }
    }
}


// =========================================================
// QR SCANNER UI
// =========================================================

@Composable
fun QRScannerUI(
    onClose: () -> Unit,
    onQrDetected: (String) -> Unit
) {

    val context =
        LocalContext.current


    val lifecycleOwner =
        LocalLifecycleOwner.current


    val previewView =
        remember {
            PreviewView(context)
        }


    val scannerOptions =
        remember {

            BarcodeScannerOptions.Builder()

                .setBarcodeFormats(
                    Barcode.FORMAT_QR_CODE
                )

                .build()
        }


    val scanner =
        remember {

            BarcodeScanning.getClient(
                scannerOptions
            )
        }


    val cameraExecutor =
        remember {

            Executors
                .newSingleThreadExecutor()
        }


    val detected =
        remember {

            AtomicBoolean(false)
        }


    DisposableEffect(
        lifecycleOwner
    ) {

        val cameraProviderFuture =
            ProcessCameraProvider
                .getInstance(context)


        cameraProviderFuture.addListener({

            val cameraProvider =
                cameraProviderFuture.get()


            // ---------------------------------------------
            // CAMERA PREVIEW
            // ---------------------------------------------

            val preview =
                Preview.Builder()
                    .build()
                    .also {

                        it.surfaceProvider =
                            previewView
                                .surfaceProvider
                    }


            // ---------------------------------------------
            // IMAGE ANALYSIS
            // ---------------------------------------------

            val imageAnalysis =
                ImageAnalysis.Builder()

                    .setBackpressureStrategy(
                        ImageAnalysis
                            .STRATEGY_KEEP_ONLY_LATEST
                    )

                    .build()


            imageAnalysis.setAnalyzer(
                cameraExecutor
            ) { imageProxy ->


                val mediaImage =
                    getCameraImage(
                        imageProxy
                    )


                if (
                    mediaImage != null &&
                    !detected.get()
                ) {

                    val image =
                        InputImage
                            .fromMediaImage(

                                mediaImage,

                                imageProxy
                                    .imageInfo
                                    .rotationDegrees
                            )


                    scanner
                        .process(image)

                        .addOnSuccessListener { barcodes ->

                            for (
                            barcode in barcodes
                            ) {

                                val rawValue =
                                    barcode.rawValue


                                if (
                                    !rawValue.isNullOrBlank() &&
                                    detected.compareAndSet(
                                        false,
                                        true
                                    )
                                ) {

                                    onQrDetected(
                                        rawValue
                                    )

                                    break
                                }
                            }
                        }

                        .addOnCompleteListener {

                            imageProxy.close()
                        }

                } else {

                    imageProxy.close()
                }
            }


            // ---------------------------------------------
            // START BACK CAMERA
            // ---------------------------------------------

            try {

                cameraProvider.unbindAll()


                cameraProvider.bindToLifecycle(

                    lifecycleOwner,

                    CameraSelector
                        .DEFAULT_BACK_CAMERA,

                    preview,

                    imageAnalysis
                )

            } catch (e: Exception) {

                Toast.makeText(
                    context,
                    "Unable to start camera",
                    Toast.LENGTH_LONG
                ).show()
            }

        }, ContextCompat.getMainExecutor(context))


        onDispose {

            cameraExecutor.shutdown()

            scanner.close()
        }
    }


    // ---------------------------------------------
    // CAMERA SCREEN
    // ---------------------------------------------

    Column(

        modifier =
            Modifier.fillMaxSize(),

        horizontalAlignment =
            Alignment.CenterHorizontally,

        verticalArrangement =
            Arrangement.Bottom
    ) {

        AndroidView(

            factory = {
                previewView
            },

            modifier =
                Modifier
                    .weight(1f)
                    .fillMaxSize()
        )


        Button(

            onClick = onClose,

            modifier =
                Modifier.padding(16.dp)
        ) {

            Text(
                text = "Close Scanner"
            )
        }
    }
}


// =========================================================
// CAMERAX IMAGE HELPER
// =========================================================

@OptIn(ExperimentalGetImage::class)
private fun getCameraImage(
    imageProxy: ImageProxy
): Image? {

    return imageProxy.image
}
