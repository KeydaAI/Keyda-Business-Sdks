# Shipped inside the AAR, so a consuming app's R8 run reads it automatically. Nothing here has to
# be copied into anyone's proguard-rules.pro.
#
# WHAT NEEDS KEEPING, AND WHY THE LIST IS THIS SHORT
#
#   in.keyda.bot.KeydaBotActivity   Kept already: AAPT2 turns every <activity> in the merged
#                                   manifest into a keep rule, because Android instantiates it by
#                                   name. Restating it here would only hide a future mistake -
#                                   if the activity is ever dropped from the manifest, we want the
#                                   loud ClassNotFoundException, not a silently kept class.
#   in.keyda.bot.KeydaBot           Kept by being called from the app's own code.
#
# There is no reflection in this SDK, no @JavascriptInterface bridge into the page, and nothing
# serialized. Those are the three things that normally need explicit keeps, and none of them
# apply. If a JS bridge is ever added, it needs its own rule -
#   -keepclassmembers class in.keyda.bot.** { @android.webkit.JavascriptInterface <methods>; }
# because R8 cannot see calls that arrive from JavaScript, and a stripped bridge method fails only
# at runtime, in release, in front of a customer.

# THE ONE RULE THAT IS REAL
#
# KeydaBotActivity references android.window.OnBackInvokedCallback / OnBackInvokedDispatcher (API
# 33) to support predictive back, guarded by a version check at runtime. An app that compiles
# against an SDK older than 33 does not have those classes on R8's classpath, and R8 in AGP 8
# treats missing classes as a build ERROR, not a warning: the app would fail to build the moment it
# added this SDK.
-dontwarn android.window.OnBackInvokedCallback
-dontwarn android.window.OnBackInvokedDispatcher
