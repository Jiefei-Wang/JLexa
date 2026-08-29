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
    jstring language,
    jobject progress_callback
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

    std::function<void(int)> progress_fn = nullptr;
    jclass progressClass = nullptr;
    jmethodID onProgressMethod = nullptr;
    if (progress_callback) {
        progressClass = env->GetObjectClass(progress_callback);
        if (progressClass) {
            onProgressMethod = env->GetMethodID(progressClass, "onProgress", "(I)V");
            if (onProgressMethod) {
                progress_fn = [env, progress_callback, onProgressMethod](int prog) {
                    env->CallVoidMethod(progress_callback, onProgressMethod, static_cast<jint>(prog));
                };
            }
        }
    }

    auto segments = JLexaWhisperBridge::instance().transcribe(
        pcm_data,
        n_samples,
        n_threads,
        lang,
        progress_fn
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
        if (env->PushLocalFrame(32) < 0) {
            continue; // Out of memory
        }

        jobject segMap = env->NewObject(hashMapClass, hashMapInit);

        jstring kStart = env->NewStringUTF("start_ms");
        jobject vStart = env->CallStaticObjectMethod(longClass, longValueOf, (jlong)seg.start_ms);
        env->CallObjectMethod(segMap, hashMapPut, kStart, vStart);

        jstring kEnd = env->NewStringUTF("end_ms");
        jobject vEnd = env->CallStaticObjectMethod(longClass, longValueOf, (jlong)seg.end_ms);
        env->CallObjectMethod(segMap, hashMapPut, kEnd, vEnd);

        jstring kText = env->NewStringUTF("text");
        jstring vText = env->NewStringUTF(seg.text.c_str());
        env->CallObjectMethod(segMap, hashMapPut, kText, vText);

        jstring kConf = env->NewStringUTF("confidence");
        jobject vConf = env->CallStaticObjectMethod(doubleClass, doubleValueOf, (jdouble)seg.confidence);
        env->CallObjectMethod(segMap, hashMapPut, kConf, vConf);

        // Tokens
        jobject tokenList = env->NewObject(arrayListClass, arrayListInit);
        for (const auto& tok : seg.tokens) {
            if (env->PushLocalFrame(16) < 0) continue;

            jobject tokMap = env->NewObject(hashMapClass, hashMapInit);
            jstring tkText = env->NewStringUTF("text");
            jstring tvText = env->NewStringUTF(tok.text.c_str());
            env->CallObjectMethod(tokMap, hashMapPut, tkText, tvText);

            jstring tkStart = env->NewStringUTF("start_ms");
            jobject tvStart = env->CallStaticObjectMethod(longClass, longValueOf, (jlong)tok.start_ms);
            env->CallObjectMethod(tokMap, hashMapPut, tkStart, tvStart);

            jstring tkEnd = env->NewStringUTF("end_ms");
            jobject tvEnd = env->CallStaticObjectMethod(longClass, longValueOf, (jlong)tok.end_ms);
            env->CallObjectMethod(tokMap, hashMapPut, tkEnd, tvEnd);

            jstring tkConf = env->NewStringUTF("confidence");
            jobject tvConf = env->CallStaticObjectMethod(doubleClass, doubleValueOf, (jdouble)tok.confidence);
            env->CallObjectMethod(tokMap, hashMapPut, tkConf, tvConf);

            env->CallBooleanMethod(tokenList, arrayListAdd, tokMap);
            env->PopLocalFrame(nullptr);
        }

        jstring kTokens = env->NewStringUTF("tokens");
        env->CallObjectMethod(segMap, hashMapPut, kTokens, tokenList);

        env->CallBooleanMethod(resultList, arrayListAdd, segMap);
        env->PopLocalFrame(nullptr);
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
    jobject callback
) {
    if (!prompt || !callback) return;
    const char* prompt_cstr = env->GetStringUTFChars(prompt, nullptr);
    std::string prompt_str = prompt_cstr;
    env->ReleaseStringUTFChars(prompt, prompt_cstr);

    jclass callbackClass = env->GetObjectClass(callback);
    jmethodID onTokenMethod = env->GetMethodID(callbackClass, "onToken", "(Ljava/lang/String;)V");
    jmethodID onCompleteMethod = env->GetMethodID(callbackClass, "onComplete", "(ZLjava/lang/String;)V");

    JLexaLlamaBridge::instance().generate(
        prompt_str,
        max_tokens,
        temperature,
        top_p,
        [env, callback, onTokenMethod](const std::string& token) {
            if (env->PushLocalFrame(8) < 0) return;
            jstring jtoken = env->NewStringUTF(token.c_str());
            env->CallVoidMethod(callback, onTokenMethod, jtoken);
            env->PopLocalFrame(nullptr);
        },
        [env, callback, onCompleteMethod](bool cancelled, const std::string& errorMsg) {
            if (onCompleteMethod) {
                if (env->PushLocalFrame(8) < 0) return;
                jstring jerr = env->NewStringUTF(errorMsg.c_str());
                env->CallVoidMethod(callback, onCompleteMethod, (jboolean)(cancelled ? JNI_TRUE : JNI_FALSE), jerr);
                env->PopLocalFrame(nullptr);
            }
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
