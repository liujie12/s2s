package com.s2s.server.search;

/**
 * 搜索同义词词条（{@code category_synonym} 一行）。
 *
 * @param term           词条文本（中文或拼音缩写）
 * @param pinyin         拼音首字母（小写，可空）
 * @param leafCategoryId 目标叶子类目 ID
 * @param weight         词条权重（越大越优先）
 */
public record CategorySynonym(String term, String pinyin, Integer leafCategoryId, Integer weight) {
}
