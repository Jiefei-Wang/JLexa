#include <jni.h>
#include <string>
#include <vector>
#include "jlexa_whisper_bridge.h"
#include "jlexa_llama_bridge.h"

extern "C" {

// ==========================================
// WHISPER JNI
// ==========================================

JNIEXPORT jboolean JNICALL
Java_com_example_local_1ai_1app_WhisperBridge_nativeLoadModel(
    JNIEnv* env,
    jobject /* this */,
    jstring model_path
) {
    if (!model_path) return JNI_FALSE;
    const char* path = env->GetStringUTFChars(model_path, nullptr);
    bool result = JLexaWhisperBridge::instance().loadModel(path);
    env->ReleaseStringUTFChars(model_path, path);
    return result ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT void JNICALL
Java_com_example_local_1ai_1app_WhisperBridge_nativeUnloadModel(
    JNIEnv* /* env */,
    jobject /* this */
) {
    JLexaWhisperBridge::instance().unloadModel();
}

JNIEXPORT jboolean JNICALL
Java_com_example_local_1ai_1app_WhisperBridge_nativeIsModelLoaded(
    JNIEnv* /* env */,
    jobject /* this */
) {
    return JLexaWhisperBridge::instance().isModelLoaded() ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jobject JNICALL
Java_com_example_local_1ai_1app_WhisperBridge_nativeTranscribe(
    JNIEnv* env,
    jobject /* this */,
    jfloatArray samples,
    jint n_threads,
    jstring language
) {
    if (!samples) return nullptr;

    jsize n_samples = env->GetArrayLength(samples);
    jfloat* pcm_data = env->GetFloatArrayElements(samples, nullptr);

    std::string lang = "en";
    if (language) {
        const char* lang_cstr = env->GetStringUTFChars(language, nullptr);
        lang = lang_cstr;
        env->ReleaseStringUTFChars(language, lang_cstr);
    }

    auto segments = JLexaWhisperBridge::instance().transcribe(
        pcm_data,
        n_samples,
        n_threads,
        lang,
        nullptr
    );

    env->ReleaseFloatArrayElements(samples, pcm_data, JNI_ABORT);

    // Build Java List<Map<String, Object>>
    jclass arrayListClass = env->FindClass("java/util/ArrayList");
    jmethodID arrayListInit = env->GetMethodID(arrayListClass, "<init>", "()V");
    jmethodID arrayListAdd = env->GetMethodID(arrayListClass, "add", "(Ljava/lang/Object;)Z");

    jclass hashMapClass = env->FindClass("java/util/HashMap");
    jmethodID hashMapInit = env->GetMethodID(hashMapClass, "<init>", "()V");
    jmethodID hashMapPut = env->GetMethodID(hashMapClass, "put", "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;");

    jclass longClass = env->FindClass("java/lang/Long");
    jmethodID longValueOf = env->GetStaticMethodID(longClass, "valueOf", "(J)Ljava/lang/Long;");

    jclass doubleClass = env->FindClass("java/lang/Double");
    jmethodID doubleValueOf = env->GetStaticMethodID(doubleClass, "valueOf", "(D)Ljava/lang/Double;");

    jobject resultList = env->NewObject(arrayListClass, arrayListInit);

    for (const auto& seg : segments) {
        jobject segMap = env->NewObject(hashMapClass, hashMapInit);

        env->CallObjectMethod(segMap, hashMapPut, env->NewStringUTF("start_ms"), env->CallStaticObjectMethod(longClass, longValueOf, (jlong)seg.start_ms));
        env->CallObjectMethod(segMap, hashMapPut, env->NewStringUTF("end_ms"), env->CallStaticObjectMethod(longClass, longValueOf, (jlong)seg.end_ms));
        env->CallObjectMethod(segMap, hashMapPut, env->NewStringUTF("text"), env->NewStringUTF(seg.text.c_str()));
        env->CallObjectMethod(segMap, hashMapPut, env->NewStringUTF("confidence"), env->CallStaticObjectMethod(doubleClass, doubleValueOf, (jdouble)seg.confidence));

        // Tokens
        jobject tokenList = env->NewObject(arrayListClass, arrayListInit);
        for (const auto& tok : seg.tokens) {
            jobject tokMap = env->NewObject(hashMapClass, hashMapInit);
            env->CallObjectMethod(tokMap, hashMapPut, env->NewStringUTF("text"), env->NewStringUTF(tok.text.c_str()));
            env->CallObjectMethod(tokMap, hashMapPut, env->NewStringUTF("start_ms"), env->CallStaticObjectMethod(longClass, longValueOf, (jlong)tok.start_ms));
            env->CallObjectMethod(tokMap, hashMapPut, env->NewStringUTF("end_ms"), env->CallStaticObjectMethod(longClass, longValueOf, (jlong)tok.end_ms));
            env->CallObjectMethod(tokMap, hashMapPut, env->NewStringUTF("confidence"), env->CallStaticObjectMethod(doubleClass, doubleValueOf, (jdouble)tok.confidence));

            env->CallBooleanMethod(tokenList, arrayListAdd, tokMap);
            env->DeleteLocalRef(tokMap);
        }

        env->CallObjectMethod(segMap, hashMapPut, env->NewStringUTF("tokens"), tokenList);
        env->CallBooleanMethod(resultList, arrayListAdd, segMap);

        env->DeleteLocalRef(tokenList);
        env->DeleteLocalRef(segMap);
    }

    return resultList;
}

JNIEXPORT void JNICALL
Java_com_example_local_1ai_1app_WhisperBridge_nativeCancel(
    JNIEnv* /* env */,
    jobject /* this */
) {
    JLexaWhisperBridge::instance().cancel();
}

// ==========================================
// LLAMA JNI
// ==========================================

JNIEXPORT jboolean JNICALL
Java_com_example_local_1ai_1app_LlamaBridge_nativeLoadModel(
    JNIEnv* env,
    jobject /* this */,
    jstring model_path,
    jint context_length,
    jint threads
) {
    if (!model_path) return JNI_FALSE;
    const char* path = env->GetStringUTFChars(model_path, nullptr);
    bool result = JLexaLlamaBridge::instance().loadModel(path, context_length, threads);
    env->ReleaseStringUTFChars(model_path, path);
    return result ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT void JNICALL
Java_com_example_local_1ai_1app_LlamaBridge_nativeUnloadModel(
    JNIEnv* /* env */,
    jobject /* this */
) {
    JLexaLlamaBridge::instance().unloadModel();
}

JNIEXPORT jboolean JNICALL
Java_com_example_local_1ai_1app_LlamaBridge_nativeIsModelLoaded(
    JNIEnv* /* env */,
    jobject /* this */
) {
    return JLexaLlamaBridge::instance().isModelLoaded() ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT void JNICALL
Java_com_example_local_1ai_1app_LlamaBridge_nativeGenerate(
    JNIEnv* env,
    jobject /* this */,
    jstring prompt,
    jint max_tokens,
    jfloat temperature,
    jfloat top_p,
    jobject token_callback
) {
    if (!prompt) return;
    const char* prompt_cstr = env->GetStringUTFChars(prompt, nullptr);
    std::string prompt_str = prompt_cstr;
    env->ReleaseStringUTFChars(prompt, prompt_cstr);

    jclass callbackClass = env->GetObjectClass(token_callback);
    jmethodID onTokenMethod = env->GetMethodID(callbackClass, "onToken", "(Ljava/lang/String;)V");

    JLexaLlamaBridge::instance().generate(
        prompt_str,
        max_tokens,
        temperature,
        top_p,
        [env, token_callback, onTokenMethod](const std::string& token) {
            jstring jtoken = env->NewStringUTF(token.c_str());
            env->CallVoidMethod(token_callback, onTokenMethod, jtoken);
            env->DeleteLocalRef(jtoken);
        }
    );
}

JNIEXPORT void JNICALL
Java_com_example_local_1ai_1app_LlamaBridge_nativeCancel(
    JNIEnv* /* env */,
    jobject /* this */
) {
    JLexaLlamaBridge::instance().cancel();
}

} // extern "C"
