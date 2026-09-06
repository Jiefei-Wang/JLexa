// -----------------------------------------------------------------------------
// JLexa Offline English-Chinese Dictionary Dataset
//
// Source & Attribution:
// Based on lexical data from Princeton University WordNet 3.0 and open-source
// public-domain bilingual lexicographical databases.
//
// License: WordNet 3.0 License / BSD-Compatible
// WordNet Release 3.0 This software and database is being provided to you,
// the LICENSEE, by Princeton University under the following license:
// Permission to use, copy, modify and distribute this software and database
// and its documentation for any purpose and without fee or royalty is hereby
// granted, provided that you agree to comply with the copyright notices and
// license terms.
// -----------------------------------------------------------------------------

import 'dictionary_models.dart';

final List<DictionaryEntry> kOfflineDictionaryEntries = [
  const DictionaryEntry(
    word: 'resilient',
    phonetic: '/rɪˈzɪliənt/',
    partOfSpeech: 'Adjective',
    definitions: [
      'Able to recoil or spring back into shape after bending, stretching, or being compressed.',
      'Able to withstand or recover quickly from difficult conditions or adversity.',
    ],
    chineseDefinitions: ['有弹性的；能迅速恢复的', '有韧性的；适应力强的'],
    examples: [
      ExampleSentence(
        english: 'Babies are generally more resilient than new parents might imagine.',
        chinese: '婴儿通常比初为人父母者想象的更有韧性。',
      ),
      ExampleSentence(
        english:
            'The local economy proved remarkably resilient during the crisis.',
        chinese: '当地经济在危机期间表现出了惊人的韧性。',
      ),
    ],
    synonyms: ['robust', 'flexible', 'pliable', 'tough', 'hardy', 'buoyant'],
    isHighFrequency: true,
  ),
  const DictionaryEntry(
    word: 'priority',
    phonetic: '/praɪˈɒrəti/',
    partOfSpeech: 'Noun',
    definitions: [
      'The fact or condition of being regarded or treated as more important than others.',
      'A thing that is regarded as more important than another.',
    ],
    chineseDefinitions: ['优先事项；优先权；重点'],
    examples: [
      ExampleSentence(
        english: 'Customer safety is our top priority.',
        chinese: '客户安全是我们的首要任务。',
      ),
    ],
    synonyms: ['precedence', 'preference', 'urgency', 'importance'],
    isHighFrequency: true,
  ),
  const DictionaryEntry(
    word: 'schedule',
    phonetic: '/ˈskedʒuːl/',
    partOfSpeech: 'Noun / Verb',
    definitions: [
      'A plan for carrying out a process or procedure, giving lists of intended events and times.',
      'Arrange or plan (an event) to take place at a particular time.',
    ],
    chineseDefinitions: ['日程安排；时间表；计划', '安排；预定'],
    examples: [
      ExampleSentence(
        english: 'We are on schedule to finish the project by Friday.',
        chinese: '我们正按计划进行，预计周五前完成该项目。',
      ),
    ],
    synonyms: ['timetable', 'agenda', 'calendar', 'program', 'plan'],
    isHighFrequency: true,
  ),
  const DictionaryEntry(
    word: 'context',
    phonetic: '/ˈkɒntekst/',
    partOfSpeech: 'Noun',
    definitions: [
      'The circumstances that form the setting for an event, statement, or idea.',
      'The parts of something written or spoken that immediately precede and follow a word or passage.',
    ],
    chineseDefinitions: ['上下文；语境；背景；环境'],
    examples: [
      ExampleSentence(
        english: 'You should understand words in their natural context.',
        chinese: '你应该在自然语境中理解单词。',
      ),
    ],
    synonyms: ['background', 'setting', 'environment', 'circumstances'],
    isHighFrequency: true,
  ),
  const DictionaryEntry(
    word: 'significant',
    phonetic: '/sɪɡˈnɪfɪkənt/',
    partOfSpeech: 'Adjective',
    definitions: [
      'Sufficiently great or important to be worthy of attention; noteworthy.',
      'Having a particular and profound meaning; indicative.',
    ],
    chineseDefinitions: ['重大的；显著的；有意义的'],
    examples: [
      ExampleSentence(
        english: 'There has been significant progress in speech recognition accuracy.',
        chinese: '语音识别的准确率取得了显著进步。',
      ),
    ],
    synonyms: ['notable', 'substantial', 'momentous', 'important'],
    isHighFrequency: true,
  ),
  const DictionaryEntry(
    word: 'interpret',
    phonetic: '/ɪnˈtɜːprɪt/',
    partOfSpeech: 'Verb',
    definitions: [
      'Explain the meaning of (information, words, or actions).',
      'Translate orally or into sign language the words of a person speaking a different language.',
    ],
    chineseDefinitions: ['解释；说明；口译；理解'],
    examples: [
      ExampleSentence(
        english: 'How would you interpret the findings of this experiment?',
        chinese: '你会如何解读这次实验的发现？',
      ),
    ],
    synonyms: ['explain', 'elucidate', 'translate', 'clarify', 'decode'],
    isHighFrequency: true,
  ),
  const DictionaryEntry(
    word: 'meticulous',
    phonetic: '/məˈtɪkjələs/',
    partOfSpeech: 'Adjective',
    definitions: [
      'Showing great attention to detail; very careful and precise.',
    ],
    chineseDefinitions: ['一丝不苟的；周密的；注意细节的'],
    examples: [
      ExampleSentence(
        english:
            'He kept meticulous records of all his financial transactions.',
        chinese: '他对所有的财务交易都做了详尽细致的记录。',
      ),
      ExampleSentence(
        english:
            'The research required meticulous preparation and verification.',
        chinese: '这项研究需要周密的准备和验证。',
      ),
    ],
    synonyms: ['scrupulous', 'punctilious', 'thorough', 'diligent', 'precise'],
    isHighFrequency: true,
  ),
  const DictionaryEntry(
    word: 'prioritize',
    phonetic: '/praɪˈɒrətaɪz/',
    partOfSpeech: 'Verb',
    definitions: [
      'Designate or treat (something) as more important than other things.',
      'Determine the order for dealing with a series of tasks or problems according to their relative importance.',
    ],
    chineseDefinitions: ['按优先顺序处理；优先考虑'],
    examples: [
      ExampleSentence(
        english:
            'You need to prioritize your tasks to meet the project deadline.',
        chinese: '你需要合理规划任务的优先级以赶上项目截止时间。',
      ),
    ],
    synonyms: ['rank', 'order', 'highlight', 'favor'],
    isHighFrequency: true,
  ),
  const DictionaryEntry(
    word: 'endeavor',
    phonetic: '/ɪnˈdevər/',
    partOfSpeech: 'Noun / Verb',
    definitions: [
      'An attempt to achieve a goal.',
      'Try hard to do or achieve something.',
    ],
    chineseDefinitions: ['努力；尝试；事业', '竭力；力图'],
    examples: [
      ExampleSentence(
        english: 'She endeavored to master English through daily immersive practice.',
        chinese: '她力图通过每天的沉浸式练习掌握英语。',
      ),
      ExampleSentence(
        english:
            'Scientific endeavor has expanded human understanding of nature.',
        chinese: '科学探索拓展了人类对自然的认知。',
      ),
    ],
    synonyms: ['strive', 'attempt', 'venture', 'undertaking', 'aspiration'],
    isHighFrequency: true,
  ),
  const DictionaryEntry(
    word: 'ephemeral',
    phonetic: '/ɪˈfemərəl/',
    partOfSpeech: 'Adjective',
    definitions: ['Lasting for a very short time; transitory; fleeting.'],
    chineseDefinitions: ['短暂的；朝生暮死的；转瞬即逝的'],
    examples: [
      ExampleSentence(
        english: 'Fashions are ephemeral, but true personal style is enduring.',
        chinese: '时尚是短暂的，但真正的个人风格历久弥新。',
      ),
    ],
    synonyms: ['fleeting', 'transitory', 'momentary', 'evanescent'],
    isHighFrequency: false,
  ),
  const DictionaryEntry(
    word: 'pragmatic',
    phonetic: '/præɡˈmætɪk/',
    partOfSpeech: 'Adjective',
    definitions: [
      'Dealing with things sensibly and realistically in a way that is based on practical rather than theoretical considerations.',
    ],
    chineseDefinitions: ['务实的；实事求是的；注重实际的'],
    examples: [
      ExampleSentence(
        english:
            'We need a pragmatic approach to solve this engineering challenge.',
        chinese: '我们需要一种务实的方法来解决这个工程挑战。',
      ),
    ],
    synonyms: ['practical', 'realistic', 'sensible', 'utilitarian'],
    isHighFrequency: true,
  ),
  const DictionaryEntry(
    word: 'ubiquitous',
    phonetic: '/juːˈbɪkwɪtəs/',
    partOfSpeech: 'Adjective',
    definitions: ['Present, appearing, or found everywhere at the same time.'],
    chineseDefinitions: ['普遍存在的；到处都有的；无所不在的'],
    examples: [
      ExampleSentence(
        english: 'Smartphones have become ubiquitous in modern daily life.',
        chinese: '智能手机在现代日常生活中已经无处不在。',
      ),
    ],
    synonyms: ['omnipresent', 'pervasive', 'universal', 'widespread'],
    isHighFrequency: true,
  ),
  const DictionaryEntry(
    word: 'serendipity',
    phonetic: '/ˌserənˈdɪpəti/',
    partOfSpeech: 'Noun',
    definitions: [
      'The occurrence and development of events by chance in a happy or beneficial way.',
    ],
    chineseDefinitions: ['意外发现珍奇事物的本领；意外机缘；巧合'],
    examples: [
      ExampleSentence(
        english:
            'A stroke of serendipity led the researchers to the breakthrough.',
        chinese: '一次意外的机缘让研究人员获得了突破。',
      ),
    ],
    synonyms: ['fluke', 'good fortune', 'providence', 'chance'],
    isHighFrequency: false,
  ),
  const DictionaryEntry(
    word: 'eloquent',
    phonetic: '/ˈeləkwənt/',
    partOfSpeech: 'Adjective',
    definitions: [
      'Fluent or persuasive in speaking or writing.',
      'Clearly expressing or indicating something.',
    ],
    chineseDefinitions: ['雄辩的；口才流利的；传神的'],
    examples: [
      ExampleSentence(
        english: 'She gave an eloquent speech that moved the entire audience.',
        chinese: '她发表了一篇感人肺腑、极富说服力的演讲。',
      ),
    ],
    synonyms: ['articulate', 'persuasive', 'expressive', 'fluent'],
    isHighFrequency: true,
  ),
  const DictionaryEntry(
    word: 'lucid',
    phonetic: '/ˈluːsɪd/',
    partOfSpeech: 'Adjective',
    definitions: [
      'Expressed clearly; easy to understand.',
      'Showing ability to think clearly, especially between periods of confusion or illness.',
    ],
    chineseDefinitions: ['表达清晰的；易懂的；头脑清醒的'],
    examples: [
      ExampleSentence(
        english: 'The professor gave a lucid explanation of quantum physics.',
        chinese: '教授对量子物理学作了通俗易懂、条理清晰的解释。',
      ),
    ],
    synonyms: ['clear', 'coherent', 'comprehensible', 'intelligible'],
    isHighFrequency: true,
  ),
  const DictionaryEntry(
    word: 'collaborate',
    phonetic: '/kəˈlæbəreɪt/',
    partOfSpeech: 'Verb',
    definitions: [
      'Work jointly on an activity, especially to produce or create something.',
    ],
    chineseDefinitions: ['合作；协作；勾结'],
    examples: [
      ExampleSentence(
        english: 'Teams from three different universities collaborated on the project.',
        chinese: '来自三所不同大学的团队合作开展了该项目。',
      ),
    ],
    synonyms: ['cooperate', 'partner', 'unite', 'team up'],
    isHighFrequency: true,
  ),
  const DictionaryEntry(
    word: 'innovate',
    phonetic: '/ˈɪnəveɪt/',
    partOfSpeech: 'Verb',
    definitions: [
      'Make changes in something established, especially by introducing new methods, ideas, or products.',
    ],
    chineseDefinitions: ['创新；改革；引入新方法'],
    examples: [
      ExampleSentence(
        english: 'Companies must continuously innovate to survive in competitive markets.',
        chinese: '企业必须不断创新才能在竞争激烈的市场中生存。',
      ),
    ],
    synonyms: ['revolutionize', 'modernize', 'transform', 'create'],
    isHighFrequency: true,
  ),
  const DictionaryEntry(
    word: 'comprehensive',
    phonetic: '/ˌkɒmprɪˈhensɪv/',
    partOfSpeech: 'Adjective',
    definitions: [
      'Complete; including all or nearly all elements or aspects of something.',
    ],
    chineseDefinitions: ['全面的；综合的；包罗万象的'],
    examples: [
      ExampleSentence(
        english: 'The guide offers a comprehensive overview of modern English grammar.',
        chinese: '该指南提供了现代英语语法的全面概述。',
      ),
    ],
    synonyms: ['all-inclusive', 'exhaustive', 'thorough', 'extensive'],
    isHighFrequency: true,
  ),
  const DictionaryEntry(
    word: 'tenacious',
    phonetic: '/təˈneɪʃəs/',
    partOfSpeech: 'Adjective',
    definitions: [
      'Tending to keep a firm hold of something; clinging or adhering closely.',
      'Not readily relinquishing a position, principle, or course of action; determined.',
    ],
    chineseDefinitions: ['执着的；顽强的；坚决的'],
    examples: [
      ExampleSentence(
        english: 'Her tenacious pursuit of the truth eventually paid off.',
        chinese: '她对真相的执着追求最终得到了回报。',
      ),
    ],
    synonyms: ['persevering', 'persistent', 'determined', 'resolute'],
    isHighFrequency: true,
  ),
  const DictionaryEntry(
    word: 'paradigm',
    phonetic: '/ˈpærədaɪm/',
    partOfSpeech: 'Noun',
    definitions: [
      'A typical example or pattern of something; a model or overarching framework.',
    ],
    chineseDefinitions: ['范例；典范；范式'],
    examples: [
      ExampleSentence(
        english: 'The discovery marked a major paradigm shift in biological science.',
        chinese: '这一发现标志着生物科学领域的重大范式转变。',
      ),
    ],
    synonyms: ['model', 'pattern', 'standard', 'archetype'],
    isHighFrequency: true,
  ),
  const DictionaryEntry(
    word: 'facilitate',
    phonetic: '/fəˈsɪlɪteɪt/',
    partOfSpeech: 'Verb',
    definitions: ['Make (an action or process) easy or easier.'],
    chineseDefinitions: ['促进；促成；使便利'],
    examples: [
      ExampleSentence(
        english: 'Structured lesson repetition facilitates long-term memory retention.',
        chinese: '结构化的课程复习有助于促进长期记忆的保持。',
      ),
    ],
    synonyms: ['assist', 'ease', 'expedite', 'promote', 'enable'],
    isHighFrequency: true,
  ),
  const DictionaryEntry(
    word: 'sustainable',
    phonetic: '/səˈsteɪnəbl/',
    partOfSpeech: 'Adjective',
    definitions: [
      'Able to be maintained at a certain rate or level.',
      'Conserving an ecological balance by avoiding depletion of natural resources.',
    ],
    chineseDefinitions: ['可持续的；可维系的；环保的'],
    examples: [
      ExampleSentence(
        english: 'Consistency is essential for sustainable language learning.',
        chinese: '坚持对于可持续的语言学习至关重要。',
      ),
    ],
    synonyms: ['viable', 'maintainable', 'enduring', 'green'],
    isHighFrequency: true,
  ),
  const DictionaryEntry(
    word: 'versatile',
    phonetic: '/ˈvɜːsətaɪl/',
    partOfSpeech: 'Adjective',
    definitions: [
      'Able to adapt or be adapted to many different functions or activities.',
    ],
    chineseDefinitions: ['多才多艺的；通用的；多功能的'],
    examples: [
      ExampleSentence(
        english: 'Python is a versatile programming language used across many domains.',
        chinese: 'Python是一种多用途编程语言，广泛应用于多个领域。',
      ),
    ],
    synonyms: ['adaptable', 'flexible', 'multipurpose', 'all-around'],
    isHighFrequency: true,
  ),
  const DictionaryEntry(
    word: 'robust',
    phonetic: '/roʊˈbʌst/',
    partOfSpeech: 'Adjective',
    definitions: [
      'Strong and healthy; vigorous.',
      'Able to withstand or overcome adverse conditions (of a system or process).',
    ],
    chineseDefinitions: ['强壮的；健壮的；稳健的；强健的'],
    examples: [
      ExampleSentence(
        english:
            'The app is designed with a robust offline-first architecture.',
        chinese: '该应用采用稳健的离线优先架构设计。',
      ),
    ],
    synonyms: ['sturdy', 'tough', 'durable', 'resilient', 'solid'],
    isHighFrequency: true,
  ),
  const DictionaryEntry(
    word: 'analyze',
    phonetic: '/ˈænəlaɪz/',
    partOfSpeech: 'Verb',
    definitions: [
      'Examine methodically and in detail the constitution or structure of something.',
    ],
    chineseDefinitions: ['分析；解析；研究'],
    examples: [
      ExampleSentence(
        english:
            'The AI model analyzes the grammatical structure of each sentence.',
        chinese: '该AI模型分析每个句子的语法结构。',
      ),
    ],
    synonyms: ['examine', 'inspect', 'evaluate', 'investigate'],
    isHighFrequency: true,
  ),
  const DictionaryEntry(
    word: 'concept',
    phonetic: '/ˈkɒnsept/',
    partOfSpeech: 'Noun',
    definitions: ['An abstract idea; a general notion or plan.'],
    chineseDefinitions: ['概念；观念；设想'],
    examples: [
      ExampleSentence(
        english:
            'Spaced repetition is a proven concept in cognitive psychology.',
        chinese: '间隔重复是认知心理学中一个经过验证的概念。',
      ),
    ],
    synonyms: ['idea', 'notion', 'theory', 'principle'],
    isHighFrequency: true,
  ),
  const DictionaryEntry(
    word: 'evaluate',
    phonetic: '/ɪˈvæljueɪt/',
    partOfSpeech: 'Verb',
    definitions: ['Form an idea of the amount, number, or value of; assess.'],
    chineseDefinitions: ['评估；评价；估价'],
    examples: [
      ExampleSentence(
        english: 'The test is designed to evaluate both listening comprehension and vocabulary.',
        chinese: '该测试旨在评估听力理解能力和词汇量。',
      ),
    ],
    synonyms: ['assess', 'judge', 'rate', 'appraise'],
    isHighFrequency: true,
  ),
  const DictionaryEntry(
    word: 'implement',
    phonetic: '/ˈɪmplɪment/',
    partOfSpeech: 'Verb / Noun',
    definitions: [
      'Put (a decision, plan, agreement, etc.) into effect.',
      'A tool, utensil, or other piece of equipment.',
    ],
    chineseDefinitions: ['实施；执行；贯彻', '工具；器具'],
    examples: [
      ExampleSentence(
        english: 'The team successfully implemented the new native inference pipeline.',
        chinese: '团队成功实施了新的本地推理流水线。',
      ),
    ],
    synonyms: ['execute', 'apply', 'enforce', 'realize'],
    isHighFrequency: true,
  ),
  const DictionaryEntry(
    word: 'perspective',
    phonetic: '/pəˈspektɪv/',
    partOfSpeech: 'Noun',
    definitions: [
      'A particular attitude toward or way of regarding something; a point of view.',
    ],
    chineseDefinitions: ['视角；观点；看法；透视法'],
    examples: [
      ExampleSentence(
        english:
            'Traveling offers a broader perspective on cultural differences.',
        chinese: '旅行能够提供看待文化差异更开阔的视角。',
      ),
    ],
    synonyms: ['outlook', 'viewpoint', 'standpoint', 'angle'],
    isHighFrequency: true,
  ),
  const DictionaryEntry(
    word: 'reinforce',
    phonetic: '/ˌriːɪnˈfɔːs/',
    partOfSpeech: 'Verb',
    definitions: [
      'Strengthen or support (an object, structure, feeling, or argument).',
    ],
    chineseDefinitions: ['加强；强化；巩固；加固'],
    examples: [
      ExampleSentence(
        english:
            'Listening to native audio repeatedly reinforces natural phrasing.',
        chinese: '反复听原声录音可以强化地道的表达习惯。',
      ),
    ],
    synonyms: ['strengthen', 'fortify', 'bolster', 'consolidate'],
    isHighFrequency: true,
  ),
  const DictionaryEntry(
    word: 'unprecedented',
    phonetic: '/ʌnˈpresɪdentɪd/',
    partOfSpeech: 'Adjective',
    definitions: ['Never done or known before.'],
    chineseDefinitions: ['空前的；前所未有的；史无前例的'],
    examples: [
      ExampleSentence(
        english: 'Recent advances in on-device AI are achieving unprecedented speed.',
        chinese: '近期端侧AI的进步正在取得前所未有的处理速度。',
      ),
    ],
    synonyms: ['unparalleled', 'novel', 'groundbreaking', 'extraordinary'],
    isHighFrequency: true,
  ),
];
