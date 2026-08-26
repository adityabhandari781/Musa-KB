"""Split source documents into passages and apply the project topic taxonomy."""

from __future__ import annotations

import argparse
import re
from pathlib import Path

from kb_common import read_jsonl, repository_root, utc_now, word_count, write_json, write_jsonl


TAXONOMY = [
('Identity and self-reinvention',['old self','self image','self-image','alter ego','limiting belief','inner child','family name','reinvent yourself'],['identity','reinvention','self-talk','self talk','becoming','underdog']),
('Ghost Mode and environmental separation',['ghost mode','change your circle','cut off','work in silence','working silently','bad environment','people around you'],['isolate','isolation','withdraw','circle','environment','distracting']),
('Vision, purpose, and goal-setting',['definiteness of purpose','12 week year','core values','three planning horizons','desired reality','set goals','goal setting'],['vision','purpose','mission','priority','priorities','visualization','visualize','goals','manifestation']),
('Discipline, execution, and productivity',['deep work','one big thing','weekly review','daily system','phone addiction','reduce friction','self imposed penalty'],['discipline','consistent','consistency','habit','routine','execute','execution','productivity','journal','procrastination']),
('Professionalism and mastery of craft',['professional versus amateur','deliberate practice','feedback loop','respect the process','master your craft','high standards'],['professional','amateur','craft','preparation','practice','standards','mastery','mistakes']),
('Resilience and adversity',['bounce back','refuse to be a victim','turn pain into','childhood trauma','keep going','got rejected'],['resilience','adversity','failure','rejection','humiliation','trauma','pain','loss','victim','perseverance']),
('Confidence, boldness, and action',['take up space','overcome fear','be more confident','self respect','take action','stop hesitating'],['confidence','confident','bold','boldness','fear','hesitation','assertive','decisive','confrontation','courage']),
('Money and entrepreneurship',['make money online','financial freedom','provide value','escape the 9','rich people','broke people','start a business','invest in yourself'],['money','rich','broke','wealth','market','sales','entrepreneur','business','income','leverage','investment']),
('YouTube and content businesses',['youtube channel','faceless channel','automated channel','video hook','audience retention','youtube automation','content business'],['youtube','thumbnail','retention','monetization','monetize','channel','video','hook']),
('Personal branding and audience-building',['personal brand','build an audience','tell your story','social proof','be authentic','content positioning'],['branding','brand','audience','followers','storytelling','authenticity','positioning','memorable']),
('Persuasion and communication',['body language','emotion before logic','loss aversion','social proof','clear point','frame the conversation','public speaking'],['persuasion','persuade','communication','charisma','negotiate','negotiation','framing','urgency','speak','speaking']),
('Networking and social hierarchy',['high status','provide value to','social hierarchy','build relationships','power dynamics','network with'],['networking','network','status','hierarchy','connections','competence','influential','relationship']),
('Fitness and physical capability',['strength training','combat sports','progressive overload','ice bath','assault bike','hybrid athlete','martial arts'],['fitness','gym','workout','bodybuilding','strength','wrestling','running','conditioning','burpees','sprint','training']),
('Health, testosterone, and vitality',['natural testosterone','sperm health','sleep quality','sunlight exposure','diet and nutrition','supplement stack','energy management'],['testosterone','sleep','nutrition','diet','sunlight','fertility','sperm','supplements','posture','health','vitality']),
('Youth, energy, and aging',['while you are young',"while you're young",'high energy','get older','waste your youth','young and hungry'],['youth','young','aging','ageing','stamina','recovery','regret','energy','old']),
('Masculinity, responsibility, and power',['be a man','men need','male duty','controlled aggression','warrior mindset','wild man','take responsibility'],['masculinity','masculine','manhood','men','warrior','responsibility','power','respect','aggression','passive']),
('Brotherhood, friendship, and loyalty',['real friends','bro code','loyal through','cut off friends','your brothers','yes men','strong circle'],['brotherhood','brother','friends','friendship','loyalty','loyal','betrayal','betrayed','circle']),
('Family and fatherhood',['become a father','raise your children','lead by example','fatherless','protect your children','bloodline standard','home school'],['fatherhood','father','dad','family','children','child','parenting','homeschooling','bloodline']),
('Marriage, women, and gender dynamics',['find a wife','red flags','green flags','traditional roles','gender dynamics','choose a partner','get married'],['marriage','wife','woman','women','girlfriend','dating','relationship','reproduction','loyalty']),
('Spirituality and consciousness',['law of attraction','higher consciousness','power of prayer','talk to god','subconscious mind','spiritual development','law of assumption'],['god','faith','prayer','gratitude','meditation','meditate','spirituality','spiritual','consciousness','dreams','fate','duality','placebo']),
('Technology, algorithms, and attention',['phone addiction','doom scrolling','doomscrolling','algorithmic control','artificial intelligence','social media','protect your attention'],['technology','algorithm','algorithms','dopamine','phone','scrolling','attention','ai','internet','online']),
('Social conditioning and Genjutsu',['social conditioning','life script','societal hypnosis','escape the matrix','government control','mass media','covid era','genjutsu'],['conformity','conditioning','school','government','influencers','media','security','society']),
('Learning and thinking skills',['learn the fundamentals','skill stacking','critical thinking','learn from role models','higher education','go to college','process information'],['learning','learn','education','college','university','fundamentals','skill','skills','thinking','curiosity','inspiration']),
('Community and alternative living',['far from weak','unchained movement','build a village','tax haven','alternative living','real world brotherhood','independent community'],['community','village','homeschooling','homeschool','unchained','independent','movement']),
]
NON_SUBSTANTIVE = {"promotion": ['giveaway','subscribe','join telegram','telegram','comment below','like and share','course launch','mentorship','hiring','poll','launching'], "banter": ['good morning boys','good night boys','lol','lmao','haha','fuck you','shut up','versus','vs.'], "low_context": ['watch this','listen to this','thoughts?','what do you think','repost','meme'], "topical_commentary": ['andrew tate','donald trump','ufc','covid','ukraine','israel','war','scammer','lawsuit']}


def term_matches(text: str, term: str) -> int:
    return len(re.findall(rf"(?i)(?<![^\W_]){re.escape(term).replace(r'\ ', r'\s+')}(?![^\W_])", text))


def sentences(text: str) -> list[str]:
    return [match.strip() for match in re.findall(r"(?s).+?(?:[.!?]+(?=\s|$)|$)", re.sub(r"\s+", " ", text).strip()) if match.strip()]


def split_oversize(text: str, maximum: int) -> list[str]:
    if word_count(text) <= maximum:
        return [text]
    result, current, current_count = [], [], 0
    for clause in filter(None, re.split(r"(?<=[,;:])\s+", text)):
        count = word_count(clause)
        if count > maximum:
            if current: result.append(" ".join(current)); current, current_count = [], 0
            words = clause.split()
            result.extend(" ".join(words[index:index + maximum]) for index in range(0, len(words), maximum))
        elif current and current_count + count > maximum:
            result.append(" ".join(current)); current, current_count = [clause], count
        else:
            current.append(clause); current_count += count
    if current: result.append(" ".join(current))
    return result


def coherent_passages(text: str, source_type: str, target: int, maximum: int) -> list[str]:
    if source_type == "text" or word_count(text) <= maximum:
        return [text.strip()]
    result, current, count = [], [], 0
    for sentence in sentences(text):
        for unit in split_oversize(sentence, maximum):
            unit_count = word_count(unit)
            if current and count + unit_count > maximum:
                result.append(" ".join(current)); current, count = [], 0
            current.append(unit); count += unit_count
            if count >= target:
                result.append(" ".join(current)); current, count = [], 0
    if current:
        trailing = " ".join(current)
        if result and count < 60 and word_count(result[-1]) + count <= maximum: result[-1] += " " + trailing
        else: result.append(trailing)
    return result


def score_topics(text: str) -> list[dict]:
    scores = []
    for number, (title, phrases, keywords) in enumerate(TAXONOMY, 1):
        score, matched = 0.0, []
        for term, weight, cap in [(term, 2, 3) for term in phrases] + [(term, 1, 2) for term in keywords]:
            count = term_matches(text, term)
            if count:
                score += weight * min(count, cap)
                if term not in matched: matched.append(term)
        if score: scores.append({"topic_id": number, "title": title, "score": round(score, 2), "matched_terms": matched[:12]})
    return sorted(scores, key=lambda row: (-row["score"], row["topic_id"]))


def non_substantive_signals(text: str) -> tuple[float, list[dict]]:
    score, signals = 0.0, []
    for category, terms in NON_SUBSTANTIVE.items():
        for term in terms:
            count = term_matches(text, term)
            if count: score += min(count, 2); signals.append({"category": category, "term": term})
    return round(score, 2), signals


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository-root", default=None)
    parser.add_argument("--target-transcript-passage-words", type=int, default=180)
    parser.add_argument("--maximum-transcript-passage-words", type=int, default=260)
    parser.add_argument("--segmentation-manifest", default="")
    args = parser.parse_args()
    repo = repository_root(args.repository_root); build = repo / "build"; manifest = build / "source-manifest.jsonl"
    if not manifest.is_file(): raise FileNotFoundError(f"Source manifest not found. Run scripts/inventory_sources.py first: {manifest}")
    records = [row for row in read_jsonl(manifest) if row["included_in_synthesis"]]
    supplied: dict[str, list[dict]] = {}
    if args.segmentation_manifest:
        path = Path(args.segmentation_manifest); path = path if path.is_absolute() else repo / path
        if not path.is_file(): raise FileNotFoundError(f"Segmentation manifest not found: {path}")
        for segment in read_jsonl(path):
            if not segment.get("source_id") or not segment.get("text"): raise ValueError("The supplied segmentation manifest contains an invalid segment.")
            supplied.setdefault(segment["source_id"], []).append(segment)
        for record in records:
            if record["source_id"] not in supplied: raise ValueError(f"The supplied segmentation manifest omits {record['source_id']}.")
    passages = []
    for record in records:
        segments = [item["text"] for item in sorted(supplied[record["source_id"]], key=lambda item: item["segment_index"])] if args.segmentation_manifest else coherent_passages(record["normalized_text"], record["source_type"], args.target_transcript_passage_words, args.maximum_transcript_passage_words)
        for segment_index, segment in enumerate(segments, 1):
            scores, count = score_topics(segment), word_count(segment)
            top, second = (scores + [None, None])[:2]
            non_score, signals = non_substantive_signals(segment)
            low_context, weak = count < 10, top is None or top["score"] < 2
            promotion = any(item["category"] == "promotion" for item in signals); topical = any(item["category"] == "topical_commentary" for item in signals)
            route_non = low_context or top is None or ((promotion or topical) and weak)
            reasons = (["low_context"] if low_context else []) + (["no_substantive_topic_signal"] if top is None else []) + (["promotion_without_substantive_lesson"] if promotion and weak else []) + (["topical_commentary_without_substantive_lesson"] if topical and weak else [])
            if route_non:
                primary, secondary = 25, []
                candidates = sorted(scores + [{"topic_id": 25, "title": "Non-substantive material", "score": max(1, non_score), "matched_terms": list(dict.fromkeys(item["term"] for item in signals))}], key=lambda row: (-row["score"], row["topic_id"]))
            else:
                primary = top["topic_id"]
                secondary = [item["topic_id"] for item in scores if item["topic_id"] != primary and item["score"] >= top["score"] * .45][:3]
                candidates = scores
            confidence = "high" if primary == 25 and (low_context or non_score >= 2) else "medium" if top and top["score"] >= 2 else "low"
            if top and primary != 25:
                ratio = 1 if not second else top["score"] / (top["score"] + second["score"])
                if top["score"] >= 5 and ratio >= .65: confidence = "high"
            review = primary == 25 or confidence == "low" or (second is not None and abs(top["score"] - second["score"]) < 1) or len(secondary) > 2
            passages.append({"passage_id": f"P{len(passages) + 1:06d}", "source_id": record["source_id"], "source_type": record["source_type"], "relative_path": record["relative_path"], "recorded_at": record.get("recorded_at"), "segment_index": segment_index, "text": segment, "word_count": count, "primary_topic_id": primary, "secondary_topic_ids": secondary, "candidate_topics": candidates, "non_substantive_signals": signals, "routing": "non_substantive" if route_non else "substantive", "routing_reasons": reasons, "classification_confidence": confidence, "review_required": review})
    write_jsonl(build / "passage-manifest.jsonl", passages)
    summary = {"schema_version": 1, "generated_at": utc_now(), "input_canonical_source_count": len(records), "sources_with_passages": len({item["source_id"] for item in passages}), "passage_count": len(passages), "review_required_count": sum(item["review_required"] for item in passages), "non_substantive_primary_count": sum(item["primary_topic_id"] == 25 for item in passages), "confidence": {level: sum(item["classification_confidence"] == level for item in passages) for level in ["high", "medium", "low"]}, "topic_counts": [{"topic_id": topic, "primary_passage_count": sum(item["primary_topic_id"] == topic for item in passages), "secondary_passage_count": sum(topic in item["secondary_topic_ids"] for item in passages)} for topic in range(1, 26)], "files": {"passage_manifest": "build/passage-manifest.jsonl", "source_manifest": "build/source-manifest.jsonl"}}
    write_json(build / "passage-summary.json", summary)
    print(f"Classification complete: {len(passages)} passages from {len(records)} canonical sources.")


if __name__ == "__main__":
    main()
