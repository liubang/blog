---
title: "About"
date: "2017-01-01"
comment: false
toc: false
---

<!--more-->

<section class="about-page">
  <div class="about-hero">
    <img class="about-avatar" src="/images/profile.png" alt="liubang" loading="eager" decoding="async" />
    <div>
      <div class="about-meta">
        <p class="about-kicker">liubang</p>
        <div class="about-actions">
          <a href="https://github.com/liubang" target="_blank" rel="noopener noreferrer"><svg class="about-action-icon" viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61C4.422 18.07 3.633 17.7 3.633 17.7c-1.087-.744.084-.729.084-.729 1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.3-5.466-1.332-5.466-5.93 0-1.31.465-2.38 1.235-3.22-.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 1.23.96-.267 1.98-.399 3-.405 1.02.006 2.04.138 3 .405 2.28-1.552 3.285-1.23 3.285-1.23.645 1.653.24 2.873.12 3.176.765.84 1.23 1.91 1.23 3.22 0 4.61-2.805 5.625-5.475 5.92.42.36.81 1.096.81 2.22 0 1.606-.015 2.896-.015 3.286 0 .315.21.69.825.57C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12"/></svg>GitHub</a>
          <a href="mailto:it.liubang@gmail.com"><svg class="about-action-icon" viewBox="0 0 512 512" aria-hidden="true" focusable="false"><path d="M464 64H48C21.49 64 0 85.49 0 112v288c0 26.51 21.49 48 48 48h416c26.51 0 48-21.49 48-48V112c0-26.51-21.49-48-48-48zm0 48v40.805c-22.422 18.259-58.168 46.651-134.587 106.49-16.841 13.247-50.201 45.072-73.413 44.701-23.208.375-56.579-31.459-73.413-44.701C106.18 199.465 70.425 171.067 48 152.805V112h416zM48 400V214.398c22.914 18.251 55.409 43.862 104.938 82.646 21.857 17.205 60.134 55.186 103.062 54.955 42.717.231 80.509-37.199 103.053-54.947 49.528-38.783 82.032-64.401 104.947-82.653V400H48z"/></svg>Email</a>
          <a href="/index.xml"><svg class="about-action-icon" viewBox="0 0 448 512" aria-hidden="true" focusable="false"><path d="M128.081 415.959c0 35.369-28.672 64.041-64.041 64.041S0 451.328 0 415.959s28.672-64.041 64.041-64.041 64.04 28.673 64.04 64.041zm175.66 47.25c-8.354-154.6-132.185-278.587-286.95-286.95C7.656 175.765 0 183.105 0 192.253v48.069c0 8.415 6.49 15.472 14.887 16.018 111.832 7.284 201.473 96.702 208.772 208.772.547 8.397 7.604 14.887 16.018 14.887h48.069c9.149.001 16.489-7.655 15.995-16.79zm144.249.288C439.596 229.677 251.465 40.445 16.503 32.01 7.473 31.686 0 38.981 0 48.016v48.068c0 8.625 6.835 15.645 15.453 15.999 191.179 7.839 344.627 161.316 352.465 352.465.353 8.618 7.373 15.453 15.999 15.453h48.068c9.034-.001 16.329-7.474 16.005-16.504z"/></svg>RSS</a>
        </div>
      </div>
      <h2>I write code, and sometimes the thinking around it.</h2>
      <p class="about-lead">I spend most of my time around C++, storage systems, compilers, distributed systems, and engineering practice. This blog collects notes from source reading, project building, and technical exploration.</p>
    </div>
  </div>

  <div class="about-stats" aria-label="Writing topics">
    <div>
      <strong>C++</strong>
      <span>Language details, templates, runtime, and engineering</span>
    </div>
    <div>
      <strong>Storage</strong>
      <span>LSM trees, distributed protocols, and filesystem design</span>
    </div>
    <div>
      <strong>Compiler</strong>
      <span>Parsers, interpreters, query engines, and LSPs</span>
    </div>
  </div>

  <h2 class="about-section-title">Recent Focus</h2>
  <div class="about-focus">
    <a href="/minidfs/" class="about-focus-item">
      <span>MiniDFS</span>
      <p>A small distributed filesystem exercise for exploring HDFS ideas: NameNode, DataNode, write pipeline, lease, heartbeat, and replica repair.</p>
    </a>
    <a href="/flux/" class="about-focus-item">
      <span>Flux Query Engine</span>
      <p>Notes on building a query language from syntax and AST to runtime, connectors, optimizer, and language-server support.</p>
    </a>
  </div>

  <h2 class="about-section-title">Projects</h2>
  <div class="about-projects">
    <a class="about-project" href="https://github.com/algo-data-platform/LaserDB" target="_blank" rel="noopener noreferrer">
      <strong>LaserDB</strong>
      <span>A storage-system project for learning and experimentation.</span>
    </a>
    <a class="about-project" href="https://github.com/liubang/nvimrc" target="_blank" rel="noopener noreferrer">
      <strong>nvimrc</strong>
      <span>My daily Neovim configuration.</span>
    </a>
    <a class="about-project" href="https://github.com/liubang/linger_framework" target="_blank" rel="noopener noreferrer">
      <strong>linger_framework</strong>
      <span>An experimental C++ network and service framework.</span>
    </a>
    <a class="about-project" href="https://github.com/liubang/php_double_array_trie_tree" target="_blank" rel="noopener noreferrer">
      <strong>php_double_array_trie_tree</strong>
      <span>A PHP extension for double-array trie trees.</span>
    </a>
  </div>
</section>
