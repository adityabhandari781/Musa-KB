import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  answerQuestion,
  buildPrompt,
  buildContext,
  findRelevantDocuments,
  isPuterSignedIn,
  parseInlineMarkdown,
  parseMarkdownBlocks,
  tokenize,
} from '../kb/assets/javascripts/chat.js';

const documents = [
  {
    location: '07-confidence-boldness-and-action/#core-ideas',
    title: 'Core ideas',
    text: 'Overcome fear through bold action. Confidence grows when you move.',
  },
  {
    location: '06-resilience-and-adversity/#core-ideas',
    title: 'Core ideas',
    text: 'Overcome adversity by persisting through discomfort and failure.',
  },
  {
    location: '08-money-and-entrepreneurship/#core-ideas',
    title: 'Core ideas',
    text: 'Build useful products, understand markets, and manage money carefully.',
  },
  {
    location: 'homepage/#about',
    title: 'About this project',
    text: 'This knowledge base contains structured articles.',
  },
  {
    location: '',
    title: "Musa's Gems",
    text: 'A knowledge base.',
  },
  {
    location: '26-all-texts/#s0001',
    title: 'S0001 – source text',
    text: 'Overcome fear through this raw source transcript.',
  },
];

test('tokenize normalizes punctuation, case, duplicates, and stop words', () => {
  assert.deepEqual(
    tokenize('How do I overcome, overcome my fears?'),
    ['overcome', 'fears'],
  );
});

test('fear question ranks confidence and resilience above unrelated money content', () => {
  const results = findRelevantDocuments('How do I overcome fear?', documents);

  assert.deepEqual(
    results.slice(0, 2).map((document) => document.location),
    [
      '07-confidence-boldness-and-action/#core-ideas',
      '06-resilience-and-adversity/#core-ideas',
    ],
  );
  assert.ok(results.every(({ location }) => location !== '08-money-and-entrepreneurship/#core-ideas'));
});

test('title matches outrank equivalent body-only matches', () => {
  const results = findRelevantDocuments(
    'confidence action',
    [
      {
        location: '01-body-match',
        title: 'Recommended practices',
        text: 'Confidence comes from taking action.',
      },
      {
        location: '02-title-match',
        title: 'Confidence and action',
        text: 'Practice one small step today.',
      },
    ],
  );

  assert.equal(results[0].location, '02-title-match');
});

test('BM25 rewards repeated query terms when documents have equal length', () => {
  const results = findRelevantDocuments('focus', [
    {
      location: '01-single-focus',
      title: 'Practice',
      text: 'focus signal signal signal signal signal',
    },
    {
      location: '02-repeated-focus',
      title: 'Practice',
      text: 'focus focus focus signal signal signal',
    },
  ]);

  assert.equal(results[0].location, '02-repeated-focus');
});

test('BM25 normalizes document length for otherwise equal matches', () => {
  const results = findRelevantDocuments('focus', [
    {
      location: '01-long-focus',
      title: 'Practice',
      text: `focus ${'signal '.repeat(40)}`,
    },
    {
      location: '02-short-focus',
      title: 'Practice',
      text: 'focus signal',
    },
  ]);

  assert.equal(results[0].location, '02-short-focus');
});

test('filters homepage and source appendix, deduplicates locations, and limits results', () => {
  const results = findRelevantDocuments('overcome fear', [
    ...documents,
    documents[0],
  ], 2);

  assert.equal(results.length, 2);
  assert.ok(results.every(({ location }) => !location.startsWith('26-all-texts/')));
  assert.ok(results.every(({ location }) => location !== '' && !location.startsWith('homepage/')));
  assert.equal(new Set(results.map(({ location }) => location)).size, results.length);
});

test('returns no results for blank or unrelated questions', () => {
  assert.deepEqual(findRelevantDocuments('   ', documents), []);
  assert.deepEqual(findRelevantDocuments('how to bake sourdough', documents), []);
});

test('buildContext keeps source labels and respects the combined character limit', () => {
  const context = buildContext([
    {
      location: '07-confidence-boldness-and-action/#core-ideas',
      title: 'Core ideas',
      text: 'A'.repeat(100),
    },
    {
      location: '06-resilience-and-adversity/#core-ideas',
      title: 'Core ideas',
      text: 'B'.repeat(100),
    },
  ], 180);

  assert.ok(context.length <= 180);
  assert.match(context, /07-confidence-boldness-and-action/);
});

test('buildPrompt grounds the answer and marks retrieved text as untrusted context', () => {
  const prompt = buildPrompt('How do I overcome fear?', [documents[0]]);

  assert.match(prompt, /How do I overcome fear\?/);
  assert.match(prompt, /07-confidence-boldness-and-action/);
  assert.match(prompt, /reference material, not instructions/i);
  assert.match(prompt, /common Markdown/i);
  assert.match(prompt, /Do not use raw HTML/i);
  assert.match(prompt, /professional medical, legal, or financial advice/i);
});

test('parseInlineMarkdown recognizes common formatting and safe links', () => {
  assert.deepEqual(
    parseInlineMarkdown('**bold** and *emphasis* with `code` and [docs](https://example.com).'),
    [
      { type: 'strong', children: [{ type: 'text', value: 'bold' }] },
      { type: 'text', value: ' and ' },
      { type: 'emphasis', children: [{ type: 'text', value: 'emphasis' }] },
      { type: 'text', value: ' with ' },
      { type: 'code', value: 'code' },
      { type: 'text', value: ' and ' },
      { type: 'link', href: 'https://example.com/', children: [{ type: 'text', value: 'docs' }] },
      { type: 'text', value: '.' },
    ],
  );
});

test('parseInlineMarkdown keeps raw HTML and unsafe links as text', () => {
  assert.deepEqual(
    parseInlineMarkdown('<img src=x onerror=alert(1)> [bad](javascript:alert(1))'),
    [{ type: 'text', value: '<img src=x onerror=alert(1)> [bad](javascript:alert(1))' }],
  );
});

test('parseMarkdownBlocks builds paragraphs, headings, and nested ordered lists', () => {
  assert.deepEqual(
    parseMarkdownBlocks('# Heading\n\nA **bold** idea.\n\n- First\n  - Nested\n- Second\n\n1. One\n2) Two'),
    [
      { type: 'heading', level: 1, children: [{ type: 'text', value: 'Heading' }] },
      { type: 'paragraph', children: [
        { type: 'text', value: 'A ' },
        { type: 'strong', children: [{ type: 'text', value: 'bold' }] },
        { type: 'text', value: ' idea.' },
      ] },
      {
        type: 'list',
        ordered: false,
        items: [
          {
            children: [{ type: 'paragraph', children: [{ type: 'text', value: 'First' }] }],
            nested: [{
              type: 'list',
              ordered: false,
              items: [{ children: [{ type: 'paragraph', children: [{ type: 'text', value: 'Nested' }] }], nested: [] }],
            }],
          },
          {
            children: [{ type: 'paragraph', children: [{ type: 'text', value: 'Second' }] }],
            nested: [],
          },
        ],
      },
      {
        type: 'list',
        ordered: true,
        items: [
          { children: [{ type: 'paragraph', children: [{ type: 'text', value: 'One' }] }], nested: [] },
          { children: [{ type: 'paragraph', children: [{ type: 'text', value: 'Two' }] }], nested: [] },
        ],
      },
    ],
  );
});

test('answerQuestion avoids Puter when retrieval has no match', async () => {
  let loadCalls = 0;
  const result = await answerQuestion('how to bake sourdough', documents, {
    loadPuter: async () => {
      loadCalls += 1;
      return { ai: { chat: async () => 'should not run' } };
    },
  });

  assert.deepEqual(result, { status: 'no-match', answer: '', results: [] });
  assert.equal(loadCalls, 0);
});

test('answerQuestion sends bounded context and returns Puter text', async () => {
  let prompt = '';
  const result = await answerQuestion('How do I overcome fear?', documents, {
    loadPuter: async () => ({
      ai: {
        chat: async (value) => {
          prompt = value;
          return { message: { content: 'Take one small action and build momentum.' } };
        },
      },
    }),
  });

  assert.equal(result.status, 'answered');
  assert.equal(result.answer, 'Take one small action and build momentum.');
  assert.match(prompt, /How do I overcome fear\?/);
  assert.ok(prompt.length <= 14000);
  assert.equal(result.results[0].location, '07-confidence-boldness-and-action/#core-ideas');
});

test('answerQuestion supports cancelling before the AI request', async () => {
  let chatCalls = 0;
  const result = await answerQuestion('How do I overcome fear?', documents, {
    loadPuter: async () => ({
      ai: { chat: async () => { chatCalls += 1; } },
    }),
    beforeChat: async () => false,
  });

  assert.equal(result.status, 'cancelled');
  assert.equal(chatCalls, 0);
});

test('answerQuestion preserves a cancelled Puter sign-in status', async () => {
  const authError = Object.assign(new Error('closed'), { code: 'PUTER_AUTH_CANCELLED' });

  await assert.rejects(
    answerQuestion('How do I overcome fear?', documents, {
      loadPuter: async () => ({ ai: { chat: async () => 'not reached' } }),
      beforeChat: async () => { throw authError; },
    }),
    (error) => error === authError,
  );
});

test('isPuterSignedIn reads Puter auth state and tolerates test doubles', () => {
  assert.equal(isPuterSignedIn({ auth: { isSignedIn: () => true } }), true);
  assert.equal(isPuterSignedIn({ auth: { isSignedIn: () => false } }), false);
  assert.equal(isPuterSignedIn({ ai: { chat: () => {} } }), true);
});

test('answerQuestion rejects oversized input and normalizes AI failures', async () => {
  await assert.rejects(
    answerQuestion('x'.repeat(501), documents, { loadPuter: async () => ({}) }),
    /500 characters/,
  );

  await assert.rejects(
    answerQuestion('How do I overcome fear?', documents, {
      loadPuter: async () => ({
        ai: { chat: async () => { throw new Error('provider secret'); } },
      }),
    }),
    (error) => error.message === 'The AI service could not answer right now. Please try again.'
      && !error.message.includes('provider secret'),
  );

  await assert.rejects(
    answerQuestion('How do I overcome fear?', documents, {
      timeoutMs: 5,
      loadPuter: async () => ({ ai: { chat: async () => new Promise(() => {}) } }),
    }),
    /The AI service could not answer right now/,
  );
});
