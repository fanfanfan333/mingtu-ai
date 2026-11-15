package com.mingtu.ai.mingtu_ai

/** Android key values are passed in so this rule can run on the plain JVM. */
object HeadsetKeyFilter {
    fun accepts(resumed: Boolean, keyCode: Int, action: Int, repeatCount: Int): Boolean =
        resumed && (keyCode == 79 || keyCode == 85) && action == 0 && repeatCount == 0
}
