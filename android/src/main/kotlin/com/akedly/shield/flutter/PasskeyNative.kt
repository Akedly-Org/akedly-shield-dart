package com.akedly.shield.flutter

import android.app.Activity
import android.content.Context
import android.os.Build
import androidx.credentials.CreatePublicKeyCredentialRequest
import androidx.credentials.CreatePublicKeyCredentialResponse
import androidx.credentials.CredentialManager
import androidx.credentials.GetCredentialRequest
import androidx.credentials.GetPublicKeyCredentialOption
import androidx.credentials.PublicKeyCredential
import androidx.credentials.exceptions.CreateCredentialCancellationException
import androidx.credentials.exceptions.CreateCredentialNoCreateOptionException
import androidx.credentials.exceptions.CreateCredentialProviderConfigurationException
import androidx.credentials.exceptions.CreateCredentialUnsupportedException
import androidx.credentials.exceptions.GetCredentialCancellationException
import androidx.credentials.exceptions.GetCredentialProviderConfigurationException
import androidx.credentials.exceptions.GetCredentialUnsupportedException
import androidx.credentials.exceptions.NoCredentialException
import androidx.credentials.exceptions.domerrors.AbortError
import androidx.credentials.exceptions.domerrors.ConstraintError
import androidx.credentials.exceptions.domerrors.DataCloneError
import androidx.credentials.exceptions.domerrors.DataError
import androidx.credentials.exceptions.domerrors.DomError
import androidx.credentials.exceptions.domerrors.EncodingError
import androidx.credentials.exceptions.domerrors.HierarchyRequestError
import androidx.credentials.exceptions.domerrors.InUseAttributeError
import androidx.credentials.exceptions.domerrors.InvalidCharacterError
import androidx.credentials.exceptions.domerrors.InvalidModificationError
import androidx.credentials.exceptions.domerrors.InvalidNodeTypeError
import androidx.credentials.exceptions.domerrors.InvalidStateError
import androidx.credentials.exceptions.domerrors.NamespaceError
import androidx.credentials.exceptions.domerrors.NetworkError
import androidx.credentials.exceptions.domerrors.NoModificationAllowedError
import androidx.credentials.exceptions.domerrors.NotAllowedError
import androidx.credentials.exceptions.domerrors.NotFoundError
import androidx.credentials.exceptions.domerrors.NotReadableError
import androidx.credentials.exceptions.domerrors.NotSupportedError
import androidx.credentials.exceptions.domerrors.OperationError
import androidx.credentials.exceptions.domerrors.OptOutError
import androidx.credentials.exceptions.domerrors.QuotaExceededError
import androidx.credentials.exceptions.domerrors.ReadOnlyError
import androidx.credentials.exceptions.domerrors.SecurityError
import androidx.credentials.exceptions.domerrors.SyntaxError
import androidx.credentials.exceptions.domerrors.TimeoutError
import androidx.credentials.exceptions.domerrors.TransactionInactiveError
import androidx.credentials.exceptions.domerrors.UnknownError
import androidx.credentials.exceptions.domerrors.VersionError
import androidx.credentials.exceptions.domerrors.WrongDocumentError
import androidx.credentials.exceptions.publickeycredential.CreatePublicKeyCredentialDomException
import androidx.credentials.exceptions.publickeycredential.GetPublicKeyCredentialDomException
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import kotlin.coroutines.cancellation.CancellationException

/** Describes a failure from an Android Credential Manager passkey ceremony. */
class AkedlyPasskeyNativeException(
    val reason: Reason,
    message: String,
    cause: Throwable? = null,
    val domError: String? = null
) : Exception(message, cause) {
    /** Stable categories for native passkey failures. */
    enum class Reason {
        UNSUPPORTED,
        CANCELLED,
        NO_CREDENTIAL,
        INVALID_OPTIONS,
        FAILED
    }
}

internal class AkedlyPasskeyNativeCore(
    private val sdkInt: () -> Int,
    private val isSupported: () -> Boolean
) {
    suspend fun run(
        optionsJson: String,
        platformCall: suspend (String) -> String
    ): String {
        if (sdkInt() < Build.VERSION_CODES.P || !isSupported()) {
            throw AkedlyPasskeyNativeException(
                reason = AkedlyPasskeyNativeException.Reason.UNSUPPORTED,
                message = "Native passkeys require Android 9 or a supported credential provider."
            )
        }
        return try {
            platformCall(optionsJson)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            throw mapCredentialFailure(error)
        }
    }
}

internal class AkedlyCredentialManagerAdapter(
    private val credentialManagerFactory: (Context) -> CredentialManager = { context ->
        CredentialManager.create(context)
    }
) {
    suspend fun register(activity: Activity, optionsJson: String): String {
        val request = CreatePublicKeyCredentialRequest(optionsJson)
        val response = credentialManagerFactory(activity).createCredential(activity, request)
        return (response as? CreatePublicKeyCredentialResponse)?.registrationResponseJson
            ?: throw IllegalStateException(
                "Credential Manager returned a non-passkey registration response."
            )
    }

    suspend fun authenticate(activity: Activity, optionsJson: String): String {
        val option = GetPublicKeyCredentialOption(optionsJson)
        val request = GetCredentialRequest(listOf(option))
        val response = credentialManagerFactory(activity).getCredential(activity, request)
        return (response.credential as? PublicKeyCredential)
            ?.authenticationResponseJson
            ?: throw IllegalStateException(
                "Credential Manager returned a non-passkey authentication response."
            )
    }
}

internal fun nativeIsSupported(context: Context): Boolean {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return false
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return true
    return runCatching {
        GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(context) ==
            ConnectionResult.SUCCESS
    }.getOrDefault(false)
}

private val credentialManagerAdapter = AkedlyCredentialManagerAdapter()

internal suspend fun nativeRegister(activity: Activity, optionsJson: String): String =
    nativeCore(activity).run(optionsJson) { json ->
        credentialManagerAdapter.register(activity, json)
    }

internal suspend fun nativeAuthenticate(activity: Activity, optionsJson: String): String =
    nativeCore(activity).run(optionsJson) { json ->
        credentialManagerAdapter.authenticate(activity, json)
    }

private fun nativeCore(activity: Activity) =
    AkedlyPasskeyNativeCore(
        sdkInt = { Build.VERSION.SDK_INT },
        isSupported = { nativeIsSupported(activity) }
    )

internal fun mapCredentialFailure(error: Throwable): AkedlyPasskeyNativeException {
    if (error is CancellationException) throw error
    if (error is AkedlyPasskeyNativeException) return error
    val reason = when (error) {
        is CreateCredentialCancellationException,
        is GetCredentialCancellationException -> AkedlyPasskeyNativeException.Reason.CANCELLED

        is NoCredentialException -> AkedlyPasskeyNativeException.Reason.NO_CREDENTIAL

        is CreateCredentialProviderConfigurationException,
        is CreateCredentialUnsupportedException,
        is CreateCredentialNoCreateOptionException,
        is GetCredentialProviderConfigurationException,
        is GetCredentialUnsupportedException -> AkedlyPasskeyNativeException.Reason.UNSUPPORTED

        is IllegalArgumentException -> AkedlyPasskeyNativeException.Reason.INVALID_OPTIONS
        else -> AkedlyPasskeyNativeException.Reason.FAILED
    }
    val domError = when (error) {
        is CreatePublicKeyCredentialDomException -> webAuthnName(error.domError)
        is GetPublicKeyCredentialDomException -> webAuthnName(error.domError)
        else -> null
    }
    return AkedlyPasskeyNativeException(
        reason = reason,
        message = error.message ?: "Credential Manager passkey ceremony failed.",
        cause = error,
        domError = domError
    )
}

private fun webAuthnName(domError: DomError): String =
    when (domError) {
        is AbortError -> "AbortError"
        is ConstraintError -> "ConstraintError"
        is DataCloneError -> "DataCloneError"
        is DataError -> "DataError"
        is EncodingError -> "EncodingError"
        is HierarchyRequestError -> "HierarchyRequestError"
        is InUseAttributeError -> "InUseAttributeError"
        is InvalidCharacterError -> "InvalidCharacterError"
        is InvalidModificationError -> "InvalidModificationError"
        is InvalidNodeTypeError -> "InvalidNodeTypeError"
        is InvalidStateError -> "InvalidStateError"
        is NamespaceError -> "NamespaceError"
        is NetworkError -> "NetworkError"
        is NoModificationAllowedError -> "NoModificationAllowedError"
        is NotAllowedError -> "NotAllowedError"
        is NotFoundError -> "NotFoundError"
        is NotReadableError -> "NotReadableError"
        is NotSupportedError -> "NotSupportedError"
        is OperationError -> "OperationError"
        is OptOutError -> "OptOutError"
        is QuotaExceededError -> "QuotaExceededError"
        is ReadOnlyError -> "ReadOnlyError"
        is SecurityError -> "SecurityError"
        is SyntaxError -> "SyntaxError"
        is TimeoutError -> "TimeoutError"
        is TransactionInactiveError -> "TransactionInactiveError"
        is UnknownError -> "UnknownError"
        is VersionError -> "VersionError"
        is WrongDocumentError -> "WrongDocumentError"
        else -> "UnknownError"
    }
