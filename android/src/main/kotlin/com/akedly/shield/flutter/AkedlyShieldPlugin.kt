package com.akedly.shield.flutter

import android.app.Activity
import android.content.Context
import android.os.Build
import androidx.credentials.exceptions.CreateCredentialException
import androidx.credentials.exceptions.GetCredentialException
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlin.coroutines.cancellation.CancellationException

/** Flutter plugin registration for the Akedly native passkey bridge. */
class AkedlyShieldPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var activity: Activity? = null
    private var applicationContext: Context? = null
    private var activeResult: MethodChannel.Result? = null
    private var activeJob: Job? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        activeResult?.error(
            "cancelled",
            "The native passkey plugin was detached.",
            null
        )
        activeResult = null
        activeJob?.cancel()
        activeJob = null
        channel?.setMethodCallHandler(null)
        channel = null
        applicationContext = null
        scope.cancel()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isNativeSupported" -> result.success(isSupported())
            "register" -> beginCeremony(call, result, false)
            "authenticate" -> beginCeremony(call, result, true)
            else -> result.notImplemented()
        }
    }

    private fun isSupported(): Boolean {
        val context = applicationContext ?: return false
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.P &&
            nativeIsSupported(context)
    }

    private fun beginCeremony(
        call: MethodCall,
        result: MethodChannel.Result,
        authenticate: Boolean
    ) {
        if (activeResult != null) {
            result.error(
                "failed",
                "A native passkey ceremony is already in flight.",
                mapOf("platformCode" to "busy")
            )
            return
        }
        val currentActivity = activity
        if (currentActivity == null) {
            result.error(
                "failed",
                "The native passkey plugin is not attached to an Activity.",
                mapOf("platformCode" to "noActivity")
            )
            return
        }
        val arguments = call.arguments as? Map<*, *>
        val optionsJson = arguments?.get("optionsJson") as? String
        if (optionsJson == null) {
            result.error(
                "invalidOptions",
                "The native passkey options must be a JSON string.",
                null
            )
            return
        }
        activeResult = result
        activeJob = scope.launch {
            try {
                val response = if (authenticate) {
                    nativeAuthenticate(currentActivity, optionsJson)
                } else {
                    nativeRegister(currentActivity, optionsJson)
                }
                finishSuccess(response)
            } catch (error: CancellationException) {
                finishError(
                    AkedlyPasskeyNativeException(
                        reason = AkedlyPasskeyNativeException.Reason.CANCELLED,
                        message = "The native passkey ceremony was cancelled.",
                        cause = error
                    )
                )
            } catch (error: Throwable) {
                finishError(mapCredentialFailure(error))
            }
        }
    }

    private fun finishSuccess(response: String) {
        val callback = activeResult ?: return
        activeResult = null
        activeJob = null
        callback.success(response)
    }

    private fun finishError(error: AkedlyPasskeyNativeException) {
        val callback = activeResult ?: return
        activeResult = null
        activeJob = null
        val details = mutableMapOf<String, String>()
        error.domError?.let { details["domError"] = it }
        if (error.reason == AkedlyPasskeyNativeException.Reason.FAILED) {
            details["platformCode"] =
                (error.cause as? CreateCredentialException)?.type
                    ?: (error.cause as? GetCredentialException)?.type
                    ?: "failed"
        }
        callback.error(
            errorCode(error.reason),
            error.message,
            details.takeIf { it.isNotEmpty() }
        )
    }

    private fun errorCode(reason: AkedlyPasskeyNativeException.Reason): String =
        when (reason) {
            AkedlyPasskeyNativeException.Reason.UNSUPPORTED -> "unsupported"
            AkedlyPasskeyNativeException.Reason.CANCELLED -> "cancelled"
            AkedlyPasskeyNativeException.Reason.NO_CREDENTIAL -> "noCredential"
            AkedlyPasskeyNativeException.Reason.INVALID_OPTIONS -> "invalidOptions"
            AkedlyPasskeyNativeException.Reason.FAILED -> "failed"
        }

    private companion object {
        const val CHANNEL_NAME = "akedly_shield/passkey"
    }
}
