import matplotlib.pyplot as plt
import numpy as np

plt.style.use("seaborn-v0_8-whitegrid")

# --- Figure 1: Per-File Held-Out Metrics ---
files = ["other/11.csv\n(N=1,190)", "other/12.csv\n(N=1,048)", "other/13.csv\n(N=923)", "other/14.csv\n(N=905)", "AGGREGATE\n(N=4,066)"]
acc = [99.41, 97.04, 97.07, 97.57, 97.86]
f1  = [99.22, 94.72, 94.88, 96.38, 96.68]
fpr = [0.00,  0.00,  1.82,  2.16,  0.91]

x = np.arange(len(files))
w = 0.28

fig, ax = plt.subplots(figsize=(9, 4.5), dpi=300)
b1 = ax.bar(x - w, acc, width=w, label="Accuracy (%)", color="#2B5B84")
b2 = ax.bar(x,     f1,  width=w, label="F1-Score (%)", color="#4A8B71")
b3 = ax.bar(x + w, fpr, width=w, label="False-Positive Rate (%)", color="#C0564B")

for bars in (b1, b2, b3):
    for bar in bars:
        h = bar.get_height()
        ax.annotate(f"{h:.2f}%", xy=(bar.get_x() + bar.get_width()/2, h),
                    xytext=(0, 3), textcoords="offset points", ha="center", va="bottom", fontsize=8, fontweight="bold")

ax.set_ylim(0, 112)
ax.set_xticks(x)
ax.set_xticklabels(files, fontsize=9, fontweight="bold")
ax.set_ylabel("Percentage (%)")
ax.set_title("EdgeTwin-2S Quarantined Held-Out SKAB Evaluation (Zero-Leakage Split)", fontsize=11, fontweight="bold")
ax.legend(frameon=True, loc="upper right")
plt.tight_layout()
plt.savefig("reports/report_fig1_per_file.png")

# --- Figure 2: Baseline vs. EdgeTwin-2S Improvement ---
metrics = ["Accuracy (%)", "Precision (%)", "Recall (%)", "F1-Score (%)", "Specificity (%)"]
baseline = [93.53, 86.04, 95.70, 90.62, 92.48]
edgetwin = [97.86, 98.06, 95.33, 96.68, 99.09]

x2 = np.arange(len(metrics))
fig2, ax2 = plt.subplots(figsize=(8.5, 4.2), dpi=300)
r1 = ax2.bar(x2 - 0.18, baseline, width=0.35, label="Baseline Random Forest", color="#8C9BA5")
r2 = ax2.bar(x2 + 0.18, edgetwin, width=0.35, label="EdgeTwin-2S (CausalSKABEnsemble)", color="#2B5B84")

for bars in (r1, r2):
    for bar in bars:
        h = bar.get_height()
        ax2.annotate(f"{h:.2f}%", xy=(bar.get_x() + bar.get_width()/2, h),
                     xytext=(0, 3), textcoords="offset points", ha="center", va="bottom", fontsize=8, fontweight="bold")

ax2.set_ylim(75, 106)
ax2.set_xticks(x2)
ax2.set_xticklabels(metrics, fontsize=9, fontweight="bold")
ax2.set_ylabel("Score (%)")
ax2.set_title("Model Generalization Comparison on Held-Out Test Split (N = 4,066)", fontsize=11, fontweight="bold")
ax2.legend(frameon=True, loc="lower right")
plt.tight_layout()
plt.savefig("reports/report_fig2_comparison.png")
print("Saved report_fig1_per_file.png and report_fig2_comparison.png")