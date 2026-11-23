import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:razorpay_flutter/razorpay_flutter.dart';

import '../data/salon_repository.dart';

/// Razorpay Checkout runs on Android and iOS only. Elsewhere customers pay at
/// the salon.
bool get onlinePaymentSupported =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

/// What Razorpay Checkout reported.
class CheckoutResult {
  const CheckoutResult.success(this.paymentId, this.orderId, this.signature)
    : error = null;
  const CheckoutResult.failure(this.error)
    : paymentId = null,
      orderId = null,
      signature = null;

  final String? paymentId;
  final String? orderId;
  final String? signature;

  /// Why the payment did not complete (cancelled, network, ...).
  final String? error;

  bool get succeeded => error == null;
}

/// Opens Razorpay Checkout for [payment] and waits for the result. The
/// server must still verify a success with [SalonRepository.verifyPayment].
Future<CheckoutResult> openRazorpayCheckout(PaymentRequest payment) {
  final razorpay = Razorpay();
  final result = Completer<CheckoutResult>();

  razorpay.on(Razorpay.EVENT_PAYMENT_SUCCESS, (PaymentSuccessResponse r) {
    if (result.isCompleted) return;
    result.complete(
      r.paymentId != null && r.signature != null
          ? CheckoutResult.success(
              r.paymentId!,
              r.orderId ?? payment.orderId,
              r.signature!,
            )
          : const CheckoutResult.failure('The payment could not be verified.'),
    );
  });
  razorpay.on(Razorpay.EVENT_PAYMENT_ERROR, (PaymentFailureResponse r) {
    if (result.isCompleted) return;
    result.complete(
      CheckoutResult.failure(
        r.code == Razorpay.PAYMENT_CANCELLED
            ? 'Payment cancelled.'
            : (r.message ?? 'The payment failed.'),
      ),
    );
  });
  razorpay.on(Razorpay.EVENT_EXTERNAL_WALLET, (ExternalWalletResponse r) {
    if (result.isCompleted) return;
    result.complete(
      CheckoutResult.failure(
        'Finish paying in ${r.walletName ?? 'your wallet app'}. '
        'Your booking is confirmed once the payment arrives.',
      ),
    );
  });

  razorpay.open({
    'key': payment.keyId,
    'order_id': payment.orderId,
    'amount': payment.amount,
    'currency': payment.currency,
    'name': 'Salon Finder',
    'description': payment.name,
    'prefill': {'email': payment.email},
    'theme': {'color': '#D4AF37'},
  });

  return result.future.whenComplete(razorpay.clear);
}
