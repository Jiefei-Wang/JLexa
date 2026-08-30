#include <jni.h>
#include <string>
#include <vector>
#include "jlexa_whisper_bridge.h"
#include "jlexa_llama_bridge.h"

static jstring makeJavaStringFromUtf8(JNIEnv* env, const std::string& str) {
    if (str.empty()) {
        return env->NewStringUTF("");
    }
    jsize len = static_cast<jsize>(str.length());
    jbyteArray byteArray = env->NewByteArray(len);
    if (!byteArray) return nullptr;

    env->SetByteArrayRegion(byteArray, 0, len, reinterpret_cast<const jbyte*>(str.data()));

    jclass stringClass = env->FindClass("java/lang/String");
    jstring charsetName = env->NewStringUTF("UTF-8");
    jmethodID stringConstructor = env->GetMethodID(stringClass, "<init>", "([BLjava/lang/String;)V");

    jstring result = static_cast<jstring>(env->NewObject(stringClass, stringConstructor, byteArray, charsetName));

    env->DeleteLocalRef(byteArray);
    env->DeleteLocalRef(charsetName);
    env->DeleteLocalRef(stringClass);
    return result;
}

static std::string getStdUtf8FromJavaString(JNIEnv* env, jstring jstr) {
    if (!jstr) return "";
    
    // Use String.getBytes("UTF-8") to get standard UTF-8 bytes
    jclass stringClass = env->GetObjectClass(jstr);
    jmethodID getBytesMethod = env->GetMethodID(stringClass, "getBytes", "(Ljava/lang/String;)[B");
    jstring charsetName = env->NewStringUTF("UTF-8");
    
    jbyteArray bytes = static_cast<jbyteArray>(env->CallObjectMethod(jstr, getBytesMethod, charsetName));
    env->DeleteLocalRef(charsetName);
    env->DeleteLocalRef(stringClass);
    
    if (!bytes) return "";
    
    jsize len = env->GetArrayLength(bytes);
    std::string result(len, '\0');
    env->GetByteArrayRegion(bytes, 0, len, reinterpret_cast<jbyte*>(&result[0]));
    env->DeleteLocalRef(bytes);
    
    return result;
}

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
    std::string path = getStdUtf8FromJavaString(env, model_path);
    bool result = JLexaWhisperBridge::instance().loadModel(path);
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
    jint sample_count,
    jint n_threads,
    jstring language,
    jobject progress_callback
) {
    if (!samples) return nullptr;

    jsize array_len = env->GetArrayLength(samples);
    jsize n_samples = (sample_count > 0 && sample_count <= array_len) ? static_cast<jsize>(sample_count) : array_len;
    jfloat* pcm_data = env->GetFloatArrayElements(samples, nullptr);
    if (!pcm_data) return nullptr;

    std::string lang = "en";
    if (language) {
        lang = getStdUtf8FromJavaString(env, language);
    }

    std::function<void(int)> progress_fn = nullptr;
    if (progress_callback) {
        jclass progressClass = env->GetObjectClass(progress_callback);
        if (progressClass) {
            jmethodID onProgressMethod = env->GetMethodID(progressClass, "onProgress", "(I)V");
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
        jstring vText = makeJavaStringFromUtf8(env, seg.text);
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
            jstring tvText = makeJavaStringFromUtf8(env, tok.text);
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

JNIEXPORT void JNICALL
Java_com_example_local_1ai_1app_WhisperBridge_nativeResetCancellation(
    JNIEnv* /* env */,
    jobject /* this */
) {
    JLexaWhisperBridge::instance().resetCancellation();
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
    std::string path = getStdUtf8FromJavaString(env, model_path);
    bool result = JLexaLlamaBridge::instance().loadModel(path, context_length, threads);
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
    jint seed,
    jobjectArray chat_roles,
    jobjectArray chat_contents,
    jobject callback
) {
    if (!callback) return;

    std::string prompt_str = "";
    if (prompt) {
        prompt_str = getStdUtf8FromJavaString(env, prompt);
    }

    std::vector<JLexaChatMessage> messages;
    if (chat_roles && chat_contents) {
        jsize n_roles = env->GetArrayLength(chat_roles);
        jsize n_contents = env->GetArrayLength(chat_contents);
        jsize count = n_roles < n_contents ? n_roles : n_contents;
        for (jsize i = 0; i < count; ++i) {
            jstring rStr = static_cast<jstring>(env->GetObjectArrayElement(chat_roles, i));
            jstring cStr = static_cast<jstring>(env->GetObjectArrayElement(chat_contents, i));
            std::string r = "user";
            std::string c = "";
            if (rStr) {
                r = getStdUtf8FromJavaString(env, rStr);
                env->DeleteLocalRef(rStr);
            }
            if (cStr) {
                c = getStdUtf8FromJavaString(env, cStr);
                env->DeleteLocalRef(cStr);
            }
            messages.push_back({r, c});
        }
    }

    jclass callbackClass = env->GetObjectClass(callback);
    jmethodID onTokenMethod = env->GetMethodID(callbackClass, "onToken", "(Ljava/lang/String;)V");
    jmethodID onCompleteMethod = env->GetMethodID(callbackClass, "onComplete", "(ZLjava/lang/String;)V");

    JLexaLlamaBridge::instance().generate(
        prompt_str,
        max_tokens,
        temperature,
        top_p,
        static_cast<uint32_t>(seed),
        messages,
        [env, callback, onTokenMethod](const std::string& token) {
            if (env->PushLocalFrame(8) < 0) return;
            jstring jtoken = makeJavaStringFromUtf8(env, token);
            env->CallVoidMethod(callback, onTokenMethod, jtoken);
            env->PopLocalFrame(nullptr);
        },
        [env, callback, onCompleteMethod](bool cancelled, const std::string& errorMsg) {
            if (onCompleteMethod) {
                if (env->PushLocalFrame(8) < 0) return;
                jstring jerr = makeJavaStringFromUtf8(env, errorMsg);
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

JNIEXPORT void JNICALL
Java_com_example_local_1ai_1app_LlamaBridge_nativeResetCancellation(
    JNIEnv* /* env */,
    jobject /* this */
) {
    JLexaLlamaBridge::instance().resetCancellation();
}

} // extern "C"
